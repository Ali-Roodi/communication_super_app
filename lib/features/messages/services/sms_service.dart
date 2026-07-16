import 'package:another_telephony/telephony.dart';
import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
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
  /// Broadcast of every **outgoing** message this app persists, from any code
  /// path (composer send, scheduled delivery, "send now").
  ///
  /// `SmsService` is constructed independently by several BLoCs, so this is
  /// static: `MessageBloc` subscribes once and refreshes the conversation /
  /// inbox no matter who did the sending. Incoming messages keep using the
  /// [onMessageReceived] callback (they already drive `ReceiveMessage`).
  static final StreamController<MessageModel> _sentController =
      StreamController<MessageModel>.broadcast();

  /// Stream of outgoing messages the moment they land in the DB.
  static Stream<MessageModel> get onMessageSent => _sentController.stream;

  /// Broadcast of delivery-status changes for outgoing messages
  /// (sent → delivered, or → failed), keyed by message id. `MessageBloc`
  /// subscribes and advances the bubble tick in the open conversation.
  static final StreamController<({String messageId, MessageStatus status})>
  _statusController =
      StreamController<({String messageId, MessageStatus status})>.broadcast();

  static Stream<({String messageId, MessageStatus status})>
  get onMessageStatusChanged => _statusController.stream;

  final Telephony _telephony = Telephony.instance;
  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final NotificationService _notificationService = NotificationService();
  final NativeSmsService _nativeSmsService = NativeSmsService();
  final BlockedNumbersRepository _blockedRepository =
      BlockedNumbersRepository();
  Function(MessageModel)? onMessageReceived;
  // _imported flag moved to SharedPreferences (sms_imported_v1) — B6 fix
  StreamSubscription<SmsReceivedEvent>? _nativeSmsSubscription;
  StreamSubscription<SmsStatusEvent>? _statusSubscription;

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

      // Message id is generated BEFORE the send so the native layer can tag
      // its sent/delivered PendingIntents with it — the status report then
      // finds this exact row (see onMessageStatusChanged).
      final messageId = const Uuid().v4();

      // Use native SMS service for sending
      final result = await _nativeSmsService.sendSms(
        phoneNumber: phoneNumber,
        message: message,
        trackingId: messageId,
      );

      if (!result.success) {
        return const SmsServiceResult.fail('SMS_SEND_FAILED');
      }

      final contact = await _contactRepository.getContactByPhoneNumber(
        phoneNumber,
      );

      final messageModel = MessageModel(
        id: messageId,
        threadId: threadId,
        contactId: contact?.id,
        phoneNumber: phoneNumber,
        body: message,
        type: MessageType.sent,
        status: MessageStatus.sent,
        timestamp: DateTime.fromMillisecondsSinceEpoch(result.timestamp),
        isRead: true, // Sent messages are always marked as read
        // Provider row id from the native write-through (default-SMS-app only)
        // so a later delete can remove the exact provider row.
        deviceSmsId: result.deviceId > 0 ? result.deviceId : null,
      );

      await _messageRepository.createMessage(messageModel);
      // Tell every listening BLoC the thread changed. Without this a message
      // sent by the scheduler (or from another screen) sits in the DB until the
      // next manual reload.
      _sentController.add(messageModel);
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

                // Blocked sender: drop silently — no persist, no notification,
                // no UI event (mirrors Google Messages behavior).
                if (await _blockedRepository.isBlocked(threadId)) {
                  debugPrint('Dropped SMS from blocked number: $threadId');
                  return;
                }

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

                // NOTE: no Dart-side notification here — the native receiver
                // (SmsNotifier) already posted one with inline-reply and
                // mark-read actions. Posting a second would duplicate it.

                onMessageReceived?.call(messageModel);
              },
              onError: (error) {
                debugPrint('Error receiving SMS via native service: $error');
              },
              cancelOnError: false,
            );

            // Delivery reports: advance the message row (sent → delivered /
            // failed) and tell the BLoC so the open bubble's tick updates.
            _statusSubscription = _nativeSmsService.onSmsStatus.listen((
              event,
            ) async {
              if (event.id.isEmpty) return;
              final status = switch (event.status) {
                'delivered' => MessageStatus.delivered,
                'failed' => MessageStatus.failed,
                _ => MessageStatus.sent,
              };
              await _messageRepository.updateMessageStatus(event.id, status);
              _statusController.add((messageId: event.id, status: status));
            });

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

          // Blocked sender: drop silently (same as the native path).
          if (await _blockedRepository.isBlocked(threadId)) return;

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

  /// Maximum number of inbox/sent messages whose **content** is reconciled per
  /// sync pass.
  ///
  /// The `telephony` plugin transfers ALL matching rows through the
  /// MethodChannel as a single JSON payload.  On a device with tens of
  /// thousands of SMS this payload can exceed the Binder transaction limit
  /// (~1 MB), causing an OOM crash or a TransactionTooLargeException.
  /// Capping the content pass keeps every sync safe while still covering all
  /// recent conversations. (The deletion diff below is NOT capped — it only
  /// moves row ids, which are tiny.)
  static const int _importLimit = 500;

  /// Mirror-syncs the local message store with the device SMS provider:
  ///
  /// 1. Recent device rows (inbox + sent) are reconciled in — new messages are
  ///    imported, and rows the app already has get their `device_sms_id`
  ///    linked (see [MessageRepository.reconcileDeviceRows]).
  /// 2. Local rows whose provider row disappeared are removed — a message
  ///    deleted on the phone (by another SMS app, or before this app held the
  ///    default role) disappears here too.
  ///
  /// Runs on every app session start and on resume (cheap after the first
  /// pass: reconcile skips known rows by `device_sms_id`).
  Future<void> syncDeviceMessages({bool forceRefresh = false}) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      throw Exception('SMS permissions not granted');
    }

    // One-time: link rows imported before the v11 migration (their id IS the
    // provider row id). Cheap idempotent UPDATE afterwards.
    await _messageRepository.backfillDeviceSmsIds();

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

    const columns = [
      SmsColumn.ID,
      SmsColumn.ADDRESS,
      SmsColumn.BODY,
      SmsColumn.DATE,
    ];
    final inbox = await _telephony.getInboxSms(
      columns: columns,
      sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
    );
    final sent = await _telephony.getSentSms(
      columns: columns,
      sortOrder: [OrderBy(SmsColumn.DATE, sort: Sort.DESC)],
    );

    // ── 1. Reconcile recent content in ─────────────────────────────────────
    const int batchSize = 100;
    final inboxList = inbox.take(_importLimit).toList();
    final sentList = sent.take(_importLimit).toList();
    final batch = <MessageModel>[];

    Future<void> flush() async {
      if (batch.isEmpty) return;
      await _messageRepository.reconcileDeviceRows(batch);
      batch.clear();
      await Future.delayed(Duration.zero);
    }

    for (final message in inboxList) {
      batch.add(_createMessageModel(message, MessageType.received, contactMap));
      if (batch.length >= batchSize) await flush();
    }
    await flush();

    for (final message in sentList) {
      batch.add(_createMessageModel(message, MessageType.sent, contactMap));
      if (batch.length >= batchSize) await flush();
    }
    await flush();

    // ── 2. Remove local rows deleted on the device ─────────────────────────
    // The full (uncapped) id set from both boxes; a local row linked to a
    // provider id that is in neither box no longer exists on the device.
    final deviceIds = <int>{
      for (final m in inbox)
        if (m.id != null) m.id!,
      for (final m in sent)
        if (m.id != null) m.id!,
    };
    final removed = await _messageRepository.removeRowsMissingFromDevice(
      deviceIds,
    );
    if (removed > 0) {
      debugPrint('Device mirror-sync removed $removed locally-stale messages');
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
      // Provider row id — the key the mirror-sync diffs on.
      deviceSmsId: smsMessage.id,
    );
  }

  // ── Default SMS app role ──────────────────────────────────────────────────

  /// True when this app currently holds the default-SMS-app role.
  Future<bool> isDefaultSmsApp() => _nativeSmsService.isDefaultSmsApp();

  /// Shows the system dialog asking the user to make this app the default SMS
  /// app. Resolves to true when granted.
  Future<bool> requestDefaultSmsRole() =>
      _nativeSmsService.requestDefaultSmsRole();

  // ── Global delete (app + device provider) ─────────────────────────────────

  /// Deletes messages **globally**: from the device SMS provider (when this
  /// app is the default SMS app) and then from the local store (soft delete —
  /// keeps the dedup index row, and reconcile skips known `device_sms_id`s so
  /// the message can never resurrect).
  Future<void> deleteMessagesGlobally(List<String> messageIds) async {
    if (messageIds.isEmpty) return;
    final messages = await _messageRepository.getMessagesByIds(messageIds);
    final specs = <Map<String, Object?>>[
      for (final m in messages)
        if (m.deviceSmsId != null)
          {'deviceId': m.deviceSmsId}
        else
          {
            'body': m.body,
            'timestamp': m.timestamp.millisecondsSinceEpoch,
          },
    ];
    await _nativeSmsService.deleteSmsFromProvider(specs);
    await _messageRepository.softDeleteMessages(messageIds);
  }

  /// Deletes a whole conversation globally: every provider row for the thread
  /// address (default-SMS-app only), then the local thread.
  Future<void> deleteThreadGlobally(String threadId) async {
    // threadId IS the normalized national number — usable as the address key.
    await _nativeSmsService.deleteSmsThreadFromProvider(threadId);
    await _messageRepository.deleteThread(threadId);
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

  /// Test seam for the in-memory duplicate-SMS window. Returns true the *second*
  /// time the same (normalized address, body, timestamp) is seen within the
  /// dedup window. See [_isDuplicateSms].
  @visibleForTesting
  bool isDuplicateForTest(String address, String body, int timestamp) =>
      _isDuplicateSms(address, body, timestamp);

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
    _statusSubscription?.cancel();
    _statusSubscription = null;
    _listening = false;
    _nativeSmsService.dispose();
  }
}
