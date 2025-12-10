import 'dart:isolate';

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

    final hasPermission = await requestPermissions();
    if (!hasPermission) return;

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

    // Serialize to isolate-friendly maps
    final serialized = [
      ...inbox.map((m) => _serializeSms(m, MessageType.received)),
      ...sent.map((m) => _serializeSms(m, MessageType.sent)),
    ];

    // Map on isolate to avoid UI jank
    final models = await Isolate.run<List<MessageModel>>(() {
      return serialized.map((data) {
        final phone = data['address'] as String? ?? '';
        final normalized = _normalizePhoneNumber(phone);
        final threadId = normalized.isNotEmpty ? normalized : phone;
        final type = data['type'] as MessageType;

        final status =
            type == MessageType.sent ? MessageStatus.sent : MessageStatus.delivered;

        return MessageModel(
          id: data['id'] as String,
          threadId: threadId,
          contactId: null,
          phoneNumber: phone,
          body: data['body'] as String? ?? '',
          type: type,
          status: status,
          timestamp: DateTime.fromMillisecondsSinceEpoch(
            data['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
          ),
        );
      }).toList();
    });

    // Attach contactId using the contact map (main isolate)
    final enriched = models.map((m) {
      final normalized = _normalizePhoneNumber(m.phoneNumber);
      final contact = contactMap[normalized];
      if (contact == null) return m;
      return MessageModel(
        id: m.id,
        threadId: m.threadId,
        contactId: contact.id,
        phoneNumber: m.phoneNumber,
        body: m.body,
        type: m.type,
        status: m.status,
        timestamp: m.timestamp,
      );
    }).toList();

    // Persist (replace duplicates by ID)
    for (final message in enriched) {
      await _messageRepository.createMessage(message);
    }

    _imported = true;
  }

  Map<String, dynamic> _serializeSms(SmsMessage message, MessageType type) {
    return {
      'id': (message.id ?? const Uuid().v4()).toString(),
      'address': message.address,
      'body': message.body,
      'timestamp': message.date,
      'type': type,
    };
  }

  static String _normalizePhoneNumber(String phone) {
    return phone.replaceAll(RegExp(r'[^\\d]'), '');
  }
}


