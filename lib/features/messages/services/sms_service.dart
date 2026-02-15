import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:uuid/uuid.dart';
import 'notification_service.dart';
import 'native_sms_service.dart';
import 'dart:async';

class SmsService {
  final Telephony _telephony = Telephony.instance;
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final NotificationService _notificationService = NotificationService();
  final NativeSmsService _nativeSmsService = NativeSmsService();
  Function(MessageModel)? onMessageReceived;
  static bool _imported = false;
  StreamSubscription<SmsReceivedEvent>? _nativeSmsSubscription;
  
  // Deduplication: Track recently processed SMS to prevent duplicates
  final Set<String> _recentSmsHashes = {};
  static const int _deduplicationWindowMs = 5000; // 5 second window

  Future<bool> requestPermissions() async {
    // Request permissions via permission_handler (reliable across devices)
    final sms = await Permission.sms.request();
    final phone = await Permission.phone.request(); // some devices need phone for SMS access
    return sms.isGranted && phone.isGranted;
  }

  Future<bool> sendSms(String phoneNumber, String message) async {
    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        return false;
      }

      final normalized = _normalizePhoneNumber(phoneNumber);
      final threadId = normalized.isNotEmpty ? normalized : phoneNumber;

      // Use native SMS service for sending
      final result = await _nativeSmsService.sendSms(
        phoneNumber: phoneNumber,
        message: message,
      );

      if (!result.success) {
        return false;
      }

      final contact = await _contactRepository.getContactByPhoneNumber(
        phoneNumber,
      );

      final messageModel = MessageModel(
        id: const Uuid().v4(),
        threadId: threadId,
        contactId: contact?.id,
        phoneNumber: phoneNumber,
        body: message,
        type: MessageType.sent,
        status: MessageStatus.sent,
        timestamp: DateTime.fromMillisecondsSinceEpoch(result.timestamp),
        isRead: true, // Sent messages are always marked as read
      );

      await _messageRepository.createMessage(messageModel);
      return true;
    } on PlatformException catch (e) {
      // Handle platform-specific errors
      debugPrint('Platform error sending SMS: ${e.code} - ${e.message}');
      return false;
    } catch (e) {
      debugPrint('Error sending SMS: $e');
      return false;
    }
  }

  void listenToIncomingSms() {
    try {
      // Initialize notifications
      _notificationService.initialize();
      
      // Initialize native SMS service for receiving
      _nativeSmsService.initialize().then((_) {
        // Listen to native SMS events
        _nativeSmsSubscription = _nativeSmsService.onSmsReceived.listen(
          (SmsReceivedEvent event) async {
            final phoneNumber = event.address;
            final body = event.body;
            
            // Check for duplicates
            if (_isDuplicateSms(phoneNumber, body, event.timestamp)) {
              return; // Skip duplicate
            }
            
            final normalized = _normalizePhoneNumber(phoneNumber);
            final threadId = normalized.isNotEmpty ? normalized : phoneNumber;

            final contact = await _contactRepository.getContactByPhoneNumber(
              phoneNumber,
            );

            final messageModel = MessageModel(
              id: const Uuid().v4(),
              threadId: threadId,
              contactId: contact?.id,
              phoneNumber: phoneNumber,
              body: body,
              type: MessageType.received,
              status: MessageStatus.delivered,
              timestamp: DateTime.fromMillisecondsSinceEpoch(event.timestamp),
              isRead: false, // New received messages are unread
            );

            await _messageRepository.createMessage(messageModel);
            
            // Show notification
            await _notificationService.showSmsNotification(
              contactName: contact?.name ?? '',
              phoneNumber: phoneNumber,
              message: body,
              threadId: threadId,
            );
            
            onMessageReceived?.call(messageModel);
          },
          onError: (error) {
            debugPrint('Error receiving SMS via native service: $error');
          },
          cancelOnError: false,
        );
      }).catchError((error) {
        debugPrint('Failed to initialize native SMS service: $error');
        // Fallback to telephony plugin
        _useTelephonyFallback();
      });
    } catch (e) {
      // Silently handle errors (e.g., permission denied)
      // SMS listening will be retried when permissions are granted
      debugPrint('Error setting up SMS listener: $e');
    }
  }

  /// Fallback to telephony plugin if native implementation fails
  void _useTelephonyFallback() {
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) async {
          final phoneNumber = message.address ?? '';
          final body = message.body ?? '';
          final timestamp = DateTime.now().millisecondsSinceEpoch;
          
          // Check for duplicates
          if (_isDuplicateSms(phoneNumber, body, timestamp)) {
            return; // Skip duplicate
          }
          
          final normalized = _normalizePhoneNumber(phoneNumber);
          final threadId = normalized.isNotEmpty ? normalized : phoneNumber;

          final contact = await _contactRepository.getContactByPhoneNumber(
            phoneNumber,
          );

          final messageModel = MessageModel(
            id: const Uuid().v4(),
            threadId: threadId,
            contactId: contact?.id,
            phoneNumber: phoneNumber,
            body: body,
            type: MessageType.received,
            status: MessageStatus.delivered,
            timestamp: DateTime.fromMillisecondsSinceEpoch(timestamp),
            isRead: false, // New received messages are unread
          );

          await _messageRepository.createMessage(messageModel);
          
          // Show notification
          await _notificationService.showSmsNotification(
            contactName: contact?.name ?? '',
            phoneNumber: phoneNumber,
            message: body,
            threadId: threadId,
          );
          
          onMessageReceived?.call(messageModel);
        },
        listenInBackground: true,
      );
    } catch (e) {
      debugPrint('Telephony fallback also failed: $e');
    }
  }

  Future<void> importDeviceMessages({bool forceRefresh = false}) async {
    if (_imported && !forceRefresh) return;

    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        throw Exception('SMS permissions not granted');
      }

      // Preload contacts to map phone numbers quickly
      final contacts = await _contactRepository.getAllContacts();
      final contactMap = <String, dynamic>{};
      for (var c in contacts) {
        for (final phone in c.phoneNumbers) {
          final normalized = _normalizePhoneNumber(phone);
          if (normalized.isNotEmpty) {
            contactMap[normalized] = c;
          }
        }
        final primaryNormalized = _normalizePhoneNumber(c.phoneNumber);
        if (primaryNormalized.isNotEmpty) {
          contactMap[primaryNormalized] = c;
        }
      }

      final inbox = await _telephony.getInboxSms(
        columns: [
          SmsColumn.ID,
          SmsColumn.ADDRESS,
          SmsColumn.BODY,
          SmsColumn.DATE,
        ],
        sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
      );

      final sent = await _telephony.getSentSms(
        columns: [
          SmsColumn.ID,
          SmsColumn.ADDRESS,
          SmsColumn.BODY,
          SmsColumn.DATE,
        ],
        sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
      );

      const int batchSize = 100;
      final inboxList = inbox.toList();
      final sentList = sent.toList();
      final batch = <MessageModel>[];

      for (final message in inboxList) {
        batch.add(_createMessageModel(message, MessageType.received, contactMap));
        if (batch.length >= batchSize) {
          await _messageRepository.createMessagesBatch(batch);
          batch.clear();
          await Future.delayed(Duration.zero);
        }
      }
      if (batch.isNotEmpty) {
        await _messageRepository.createMessagesBatch(batch);
        batch.clear();
      }

      for (final message in sentList) {
        batch.add(_createMessageModel(message, MessageType.sent, contactMap));
        if (batch.length >= batchSize) {
          await _messageRepository.createMessagesBatch(batch);
          batch.clear();
          await Future.delayed(Duration.zero);
        }
      }
      if (batch.isNotEmpty) {
        await _messageRepository.createMessagesBatch(batch);
      }

      _imported = true;
    } catch (e) {
      _imported = false;
      rethrow;
    }
  }

  MessageModel _createMessageModel(
    SmsMessage smsMessage,
    MessageType type,
    Map<String, dynamic> contactMap,
  ) {
    final phone = smsMessage.address ?? '';
    final normalized = _normalizePhoneNumber(phone);
    final threadId = normalized.isNotEmpty ? normalized : phone;
    final contact = contactMap[normalized];
    final status = type == MessageType.sent ? MessageStatus.sent : MessageStatus.delivered;

    return MessageModel(
      id: (smsMessage.id ?? const Uuid().v4()).toString(),
      threadId: threadId,
      contactId: contact?.id,
      phoneNumber: phone,
      body: smsMessage.body ?? '',
      type: type,
      status: status,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        smsMessage.date ?? DateTime.now().millisecondsSinceEpoch,
      ),
      // Imported messages from device are considered already read
      isRead: true,
    );
  }

  static String _normalizePhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[^\d]'), '');
  }

  /// Generate a unique hash for SMS deduplication
  /// Uses address, body, and timestamp (rounded to nearest second)
  String _generateSmsHash(String address, String body, int timestamp) {
    final normalizedPhone = _normalizePhoneNumber(address);
    final roundedTimestamp = (timestamp / 1000).floor(); // Round to nearest second
    return '$normalizedPhone:$body:$roundedTimestamp';
  }

  /// Check if SMS is a duplicate and mark it as processed if not
  bool _isDuplicateSms(String address, String body, int timestamp) {
    final hash = _generateSmsHash(address, body, timestamp);
    
    if (_recentSmsHashes.contains(hash)) {
      debugPrint('Duplicate SMS detected and ignored: $hash');
      return true;
    }
    
    // Add to recent set
    _recentSmsHashes.add(hash);
    
    // Clean up old hashes after deduplication window
    Future.delayed(const Duration(milliseconds: _deduplicationWindowMs), () {
      _recentSmsHashes.remove(hash);
    });
    
    return false;
  }

  /// Dispose and clean up resources
  void dispose() {
    _nativeSmsSubscription?.cancel();
    _nativeSmsSubscription = null;
    _nativeSmsService.dispose();
  }
}


