import 'package:telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:uuid/uuid.dart';

class SmsService {
  final Telephony _telephony = Telephony.instance;
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  Function(MessageModel)? onMessageReceived;
  static bool _imported = false;

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

      await _telephony.sendSms(
        to: phoneNumber,
        message: message,
      );

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
        timestamp: DateTime.now(),
      );

      await _messageRepository.createMessage(messageModel);
      return true;
    } catch (e) {
      return false;
    }
  }

  void listenToIncomingSms() {
    try {
      _telephony.listenIncomingSms(
        onNewMessage: (SmsMessage message) async {
          final phoneNumber = message.address ?? '';
          final body = message.body ?? '';
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
            timestamp: DateTime.now(),
          );

          await _messageRepository.createMessage(messageModel);
          onMessageReceived?.call(messageModel);
        },
        listenInBackground: false,
      );
    } catch (e) {
      // Silently handle errors (e.g., permission denied)
      // SMS listening will be retried when permissions are granted
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

      // Fetch inbox and sent messages
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

      // Process messages (removed isolate to fix serialization error)
      final allMessages = <MessageModel>[];
      
      for (final message in inbox) {
        final model = _createMessageModel(message, MessageType.received, contactMap);
        allMessages.add(model);
      }
      
      for (final message in sent) {
        final model = _createMessageModel(message, MessageType.sent, contactMap);
        allMessages.add(model);
      }

      // Persist messages
      for (final message in allMessages) {
        await _messageRepository.createMessage(message);
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
    );
  }

  static String _normalizePhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[^\d]'), '');
  }
}


