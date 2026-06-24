import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:uuid/uuid.dart';
import 'notification_service.dart';
import 'native_sms_service.dart';
import 'dart:async';

/// Result of an SMS send operation, carrying a typed error code when sending
/// fails so callers can display an appropriate localized message.
class SmsServiceResult {
  final bool success;

  /// Error code from native layer. One of:
  ///  'NO_SIM_CARD'      – device has no active SIM
  ///  'NO_SERVICE'       – SIM present but no cellular service
  ///  'PERMISSION_DENIED'– SEND_SMS permission not granted
  ///  'SMS_SEND_FAILED'  – generic failure
  final String? errorCode;

  const SmsServiceResult._({required this.success, this.errorCode});
  const SmsServiceResult.ok() : this._(success: true);
  const SmsServiceResult.fail(String code)
    : this._(success: false, errorCode: code);
}

class SmsService {
  final Telephony _telephony = Telephony.instance;
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final NotificationService _notificationService = NotificationService();
  final NativeSmsService _nativeSmsService = NativeSmsService();
  Function(MessageModel)? onMessageReceived;
  // _imported flag moved to SharedPreferences (sms_imported_v1) — B6 fix
  StreamSubscription<SmsReceivedEvent>? _nativeSmsSubscription;

  // Guard: SMS listener should be set up exactly once per app session.
  bool _listening = false;
  bool get isListening => _listening;

  // Deduplication: Track recently processed SMS to prevent duplicates
  final Set<String> _recentSmsHashes = {};
  static const int _deduplicationWindowMs = 5000; // 5 second window

  Future<bool> requestPermissions() async {
    // Fast-path: return immediately if already granted so that calling this
    // from an already-open conversation or list screen never shows a dialog.
    final smsStatus = await Permission.sms.status;
    final phoneStatus = await Permission.phone.status;
    if (smsStatus.isGranted && phoneStatus.isGranted) return true;

    // Request only what is missing (sequential, one dialog at a time).
    final sms = smsStatus.isGranted
        ? smsStatus
        : await Permission.sms.request();
    final phone = phoneStatus.isGranted
        ? phoneStatus
        : await Permission.phone.request();
    return sms.isGranted && phone.isGranted;
  }

  Future<SmsServiceResult> sendSms(String phoneNumber, String message) async {
    try {
      final hasPermission = await requestPermissions();
      if (!hasPermission) {
        return const SmsServiceResult.fail('PERMISSION_DENIED');
      }

      final normalized = _normalizePhoneNumber(phoneNumber);
      final threadId = normalized.isNotEmpty ? normalized : phoneNumber;

      // Use native SMS service for sending
      final result = await _nativeSmsService.sendSms(
        phoneNumber: phoneNumber,
        message: message,
      );

      if (!result.success) {
        return const SmsServiceResult.fail('SMS_SEND_FAILED');
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
      return const SmsServiceResult.ok();
    } on PlatformException catch (e) {
      // Surface the native error code (NO_SIM_CARD, NO_SERVICE, etc.) directly
      // so the BLoC can show a localized message to the user.
      debugPrint('Platform error sending SMS: ${e.code} - ${e.message}');
      return SmsServiceResult.fail(e.code);
    } catch (e) {
      debugPrint('Error sending SMS: $e');
      return const SmsServiceResult.fail('SMS_SEND_FAILED');
    }
  }

  void listenToIncomingSms() {
    // Guard: only register once per app session.  A second call (e.g. from a
    // forceRefresh) would tear down and rebuild the EventChannel subscription,
    // creating a window where eventSink is null and SMS events are silently
    // dropped by the native layer.
    if (_listening) {
      debugPrint('SmsService already listening for incoming SMS, skipping');
      return;
    }
    try {
      // Initialize notifications
      _notificationService.initialize();

      // Initialize native SMS service for receiving
      _nativeSmsService
          .initialize()
          .then((_) {
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
                final threadId = normalized.isNotEmpty
                    ? normalized
                    : phoneNumber;

                final contact = await _contactRepository
                    .getContactByPhoneNumber(phoneNumber);

                final messageModel = MessageModel(
                  id: const Uuid().v4(),
                  threadId: threadId,
                  contactId: contact?.id,
                  phoneNumber: phoneNumber,
                  body: body,
                  type: MessageType.received,
                  status: MessageStatus.delivered,
                  timestamp: DateTime.fromMillisecondsSinceEpoch(
                    event.timestamp,
                  ),
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
            _listening = true;
          })
          .catchError((error) {
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

  /// Fallback to telephony plugin if native implementation fails.
  ///
  /// IMPORTANT: `listenInBackground: true` spawns a background Dart isolate
  /// using `BackgroundIsolateBinaryMessenger`.  On some Android versions the
  /// engine reference held by that isolate becomes stale when the Activity is
  /// recreated (which Android can trigger right after permission grants),
  /// causing an immediate crash.  Using `false` keeps reception foreground-only
  /// but avoids the crash; the native `SmsHandler.kt` BroadcastReceiver
  /// handles background reception anyway.
  void _useTelephonyFallback() {
    if (_listening) return;
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) async {
          final phoneNumber = message.address ?? '';
          final body = message.body ?? '';
          final timestamp = DateTime.now().millisecondsSinceEpoch;

          if (_isDuplicateSms(phoneNumber, body, timestamp)) return;

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
            isRead: false,
          );

          await _messageRepository.createMessage(messageModel);

          await _notificationService.showSmsNotification(
            contactName: contact?.name ?? '',
            phoneNumber: phoneNumber,
            message: body,
            threadId: threadId,
          );

          onMessageReceived?.call(messageModel);
        },
        // Keep false: background isolate on some Android versions crashes when
        // Activity is recreated after permission grants (see note above).
        listenInBackground: false,
      );
      _listening = true;
    } catch (e) {
      debugPrint('Telephony fallback also failed: $e');
    }
  }

  /// Maximum number of inbox/sent messages imported per session.
  ///
  /// The `telephony` plugin transfers ALL matching rows through the
  /// MethodChannel as a single JSON payload.  On a device with tens of
  /// thousands of SMS this payload can exceed the Binder transaction limit
  /// (~1 MB), causing an OOM crash or a TransactionTooLargeException.
  /// Capping the import at a reasonable number keeps the first-run safe while
  /// still showing all recent conversations.
  static const int _importLimit = 500;

  Future<void> importDeviceMessages({bool forceRefresh = false}) async {
    // B6 fix: persist the import flag across restarts via SharedPreferences
    final prefs = await SharedPreferences.getInstance();
    final alreadyImported = prefs.getBool('sms_imported_v1') ?? false;
    if (alreadyImported && !forceRefresh) return;

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
      // Cap at _importLimit: the telephony MethodChannel payload is already
      // in memory at this point; limiting here reduces DB write time and
      // prevents processing tens of thousands of rows on the main isolate.
      final inboxList = inbox.take(_importLimit).toList();
      final sentList = sent.take(_importLimit).toList();
      final batch = <MessageModel>[];

      for (final message in inboxList) {
        batch.add(
          _createMessageModel(message, MessageType.received, contactMap),
        );
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

      await prefs.setBool('sms_imported_v1', true);
    } catch (e) {
      // Do NOT reset the flag on failure — prevents infinite retry loops.
      // The user can force a refresh via forceRefresh: true if needed.
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
    final status = type == MessageType.sent
        ? MessageStatus.sent
        : MessageStatus.delivered;

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

  /// Delegates to [PhoneNormalizer.toThreadId] so that all thread IDs are
  /// produced by a single canonical implementation.
  ///
  /// Normalizes to national `09xxxxxxxxx` form:
  ///   +989120000000  →  09120000000
  ///    989120000000  →  09120000000
  ///   09120000000   →  09120000000  (unchanged)
  ///    9120000000   →  09120000000
  static String _normalizePhoneNumber(String phone) =>
      PhoneNormalizer.toThreadId(phone);

  /// Generate a unique hash for SMS deduplication.
  /// Uses address, body, and exact timestamp so the same SMS delivered twice is deduped.
  String _generateSmsHash(String address, String body, int timestamp) {
    final normalizedPhone = _normalizePhoneNumber(address);
    return '$normalizedPhone:$body:$timestamp';
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
    _listening = false;
    _nativeSmsService.dispose();
  }
}
