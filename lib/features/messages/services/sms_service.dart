import 'package:permission_handler/permission_handler.dart';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';
import '../models/message_group.dart';
import '../models/message_model.dart';
import '../repositories/group_repository.dart';
import '../repositories/message_repository.dart';
import '../repositories/thread_sim_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';
import 'package:communication_super_app/core/services/device_sync_queue.dart';
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
  /// (pending → sent → delivered, or → failed), keyed by message id.
  /// `MessageBloc` subscribes and advances the bubble tick in the open
  /// conversation.
  ///
  /// [replacement] carries the whole row when the change brought more than a
  /// status with it — the send result also learns the provider row id, the SIM
  /// the radio really used and the moment it was accepted. Null for a carrier
  /// delivery report, which knows nothing but the new status.
  static final StreamController<
    ({String messageId, MessageStatus status, MessageModel? replacement})
  >
  _statusController =
      StreamController<
        ({String messageId, MessageStatus status, MessageModel? replacement})
      >.broadcast();

  static Stream<
    ({String messageId, MessageStatus status, MessageModel? replacement})
  >
  get onMessageStatusChanged => _statusController.stream;

  final MessageRepository _messageRepository = MessageRepository();
  final ContactRepository _contactRepository = ContactRepository();
  final NotificationService _notificationService = NotificationService();
  final NativeSmsService _nativeSmsService = NativeSmsService();
  final BlockedNumbersRepository _blockedRepository =
      BlockedNumbersRepository();
  final ThreadSimRepository _threadSimRepository = ThreadSimRepository();
  final GroupRepository _groupRepository = GroupRepository();
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

  /// Minimum spacing between silent, resume-triggered device syncs. The resume
  /// sync is expensive (500+500 provider rows + per-row reconcile); resuming
  /// the app repeatedly must not re-run it every time. The once-per-session
  /// LoadThreads sync and pull-to-refresh (forceRefresh) always bypass this.
  static const Duration _resumeSyncThrottle = Duration(minutes: 2);

  /// When the last full device sync completed. Null until the first sync.
  static DateTime? _lastSyncAt;

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

  /// «گزارش تحویل» from Settings → پیامک‌ها. Mirrored here (like
  /// `DateFormatter.calendar`) because sends happen from plain services and
  /// from the native scheduled worker, neither of which can read a BLoC.
  /// Off → no delivery PendingIntent, so a bubble stops at ✓ instead of ✓✓.
  static bool deliveryReports = true;

  /// Sends [message] to [phoneNumber].
  ///
  /// [subscriptionId] names the SIM. Null means "let the platform decide",
  /// which is correct on a single-SIM phone and on a dual-SIM phone where the
  /// user pinned a system default — the native side resolves it and reports
  /// back which card was really used, so the stored row is never "unknown"
  /// when it could be named.
  ///
  /// [optimistic] writes the row **before** the radio is touched, as `pending`,
  /// and marks it `failed` if the send is refused — which is the only way a
  /// message the network rejected can stay on screen with a retry. Every
  /// user-initiated send wants that.
  ///
  /// The **scheduled** deliverer passes false: a scheduled row owns its own
  /// retry and backoff (`ScheduledMessage.withFailedAttempt`), so an optimistic
  /// insert would leave one dead «ارسال نشد» bubble in the conversation per
  /// attempt for a message that is still going to be sent.
  Future<SmsServiceResult> sendSms(
    String phoneNumber,
    String message, {
    int? subscriptionId,
    bool optimistic = true,
  }) async {
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

    String? contactId;
    try {
      contactId = (await _contactRepository.getContactByPhoneNumber(
        phoneNumber,
      ))?.id;
    } catch (_) {
      // No contacts permission, or a cold address book that failed to read.
      // The message is not worth losing over a name.
    }

    // ── Persist FIRST, as `pending` ───────────────────────────────────────
    //
    // The row is written before a single byte reaches the radio, and that is
    // the whole point: sending in airplane mode used to leave nothing behind
    // at all — the composer cleared, the bubble never appeared, and the
    // message the user typed was simply gone. Google Messages keeps it on
    // screen and marks it «ارسال نشد» with a retry, and it can only do that
    // if the message exists somewhere first.
    //
    // A local-only row (`device_sms_id` null) is never touched by the
    // mirror-sync's stale-row diff, so a failed message survives every resume.
    final pending = MessageModel(
      id: messageId,
      threadId: threadId,
      contactId: contactId,
      phoneNumber: phoneNumber,
      body: message,
      type: MessageType.sent,
      status: MessageStatus.pending,
      timestamp: DateTime.now(),
      isRead: true, // Sent messages are always marked as read
      // What was ASKED for. The send corrects it to what the radio really
      // used; until then a null stays null («unknown», never SIM 1).
      subscriptionId: subscriptionId,
    );
    if (optimistic) {
      await _messageRepository.createMessage(pending);
      // Tell every listening BLoC the thread changed. Without this a message
      // sent by the scheduler (or from another screen) sits in the DB until
      // the next manual reload.
      _sentController.add(pending);
    }

    return _transmit(pending, alreadyStored: optimistic);
  }

  // ── «پیام گروهی» — one message, one bubble, N real SMS ────────────────────

  /// Sends [body] to every member of [group] as its own SMS, and records the
  /// whole thing as **one** message in the group's conversation.
  ///
  /// This is the honest shape of a group conversation in an app with no MMS: the
  /// history is shared, the send is a fan-out, and a member's reply comes back
  /// into that member's own 1:1 chat (Google Messages behaves exactly this way
  /// with «Group MMS» off — the conversation says so).
  ///
  /// Two invariants the rest of the app depends on:
  /// * The `messages` row keeps `device_sms_id` NULL. Only one provider id fits
  ///   there and a group send makes N of them, so they live in
  ///   `message_group_targets` — which `MessageRepository.knownDeviceSmsIds`
  ///   unions, so the mirror-sync recognises every one of them and never
  ///   re-imports the message into the members' 1:1 conversations. A NULL id
  ///   also means the stale-row diff can never delete a group message.
  /// * The row is written **before** the radio is touched, as `pending`, for the
  ///   same reason a 1:1 send is (see [sendSms]): a refused send must leave the
  ///   message on screen with a retry, not lose what the user typed.
  Future<SmsServiceResult> sendGroupSms({
    required MessageGroup group,
    required String body,
    int? subscriptionId,
  }) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      return const SmsServiceResult.fail('PERMISSION_DENIED');
    }
    if (group.members.isEmpty) {
      return const SmsServiceResult.fail('SMS_SEND_FAILED');
    }

    final messageId = const Uuid().v4();
    final threadId = group.threadId;
    final pending = MessageModel(
      id: messageId,
      threadId: threadId,
      // A group thread has no single address. The thread id stands in so the
      // column is never null and the unique content index still keys on
      // something stable; nothing displays it (see [GroupThread]).
      phoneNumber: threadId,
      body: body,
      type: MessageType.sent,
      status: MessageStatus.pending,
      timestamp: DateTime.now(),
      isRead: true,
      subscriptionId: subscriptionId,
    );

    await _messageRepository.createMessage(pending);
    await _groupRepository.insertTargets([
      for (final member in group.members)
        GroupSendTarget(
          messageId: messageId,
          phoneNumber: member.phoneNumber,
          status: 'pending',
          subscriptionId: subscriptionId,
          // A per-recipient tracking id, so a carrier delivery report advances
          // the recipient it is about instead of the whole group message.
          trackingId: const Uuid().v4(),
        ),
    ]);
    // The bubble appears with ⏱ before the first radio call.
    _sentController.add(pending);

    return _fanOut(pending, await _groupRepository.targetsOf(messageId));
  }

  /// Hands one group message to the radio once per recipient and folds the
  /// outcomes back onto the single `messages` row.
  ///
  /// Shared by the first send and by «ارسال مجدد», so what a success records and
  /// what a failure leaves behind cannot drift between them — the same contract
  /// [_transmit] has for 1:1 sends.
  Future<SmsServiceResult> _fanOut(
    MessageModel message,
    List<GroupSendTarget> targets,
  ) async {
    if (targets.isEmpty) return const SmsServiceResult.fail('SMS_SEND_FAILED');

    String? firstErrorCode;
    var anySent = false;
    DateTime? acceptedAt;
    int? usedSubscription;

    for (final target in targets) {
      // Only the recipients handed in are attempted: a retry passes the failed
      // ones, so a partly-delivered group is never re-sent to the people who
      // already got it.
      try {
        final result = await _nativeSmsService.sendSms(
          phoneNumber: target.phoneNumber,
          message: message.body,
          subscriptionId: message.subscriptionId,
          trackingId: target.trackingId ?? '',
          deliveryReport: deliveryReports,
        );
        if (!result.success) {
          firstErrorCode ??= 'SMS_SEND_FAILED';
          await _groupRepository.updateTarget(
            GroupSendTarget(
              messageId: target.messageId,
              phoneNumber: target.phoneNumber,
              status: 'failed',
              subscriptionId: target.subscriptionId,
              trackingId: target.trackingId,
            ),
          );
          continue;
        }
        anySent = true;
        acceptedAt ??= DateTime.fromMillisecondsSinceEpoch(result.timestamp);
        usedSubscription ??= result.subscriptionId >= 0
            ? result.subscriptionId
            : null;
        await _groupRepository.updateTarget(
          GroupSendTarget(
            messageId: target.messageId,
            phoneNumber: target.phoneNumber,
            status: 'sent',
            deviceSmsId: result.deviceId > 0 ? result.deviceId : null,
            subscriptionId: result.subscriptionId >= 0
                ? result.subscriptionId
                : target.subscriptionId,
            trackingId: target.trackingId,
          ),
        );
      } on PlatformException catch (e) {
        debugPrint('Group send to ${target.phoneNumber} failed: ${e.code}');
        firstErrorCode ??= e.code;
        await _groupRepository.updateTarget(
          GroupSendTarget(
            messageId: target.messageId,
            phoneNumber: target.phoneNumber,
            status: 'failed',
            subscriptionId: target.subscriptionId,
            trackingId: target.trackingId,
          ),
        );
      } catch (e) {
        debugPrint('Group send to ${target.phoneNumber} failed: $e');
        firstErrorCode ??= 'SMS_SEND_FAILED';
        await _groupRepository.updateTarget(
          GroupSendTarget(
            messageId: target.messageId,
            phoneNumber: target.phoneNumber,
            status: 'failed',
            subscriptionId: target.subscriptionId,
            trackingId: target.trackingId,
          ),
        );
      }
    }

    final updated = await refreshGroupMessageStatus(
      message.id,
      // The moment the radio accepted the first copy is the message's time —
      // the composer's optimistic timestamp is from before the send.
      timestamp: acceptedAt,
      subscriptionId: usedSubscription ?? message.subscriptionId,
    );
    if (updated != null) {
      await _threadSimRepository.remember(
        updated.threadId,
        updated.subscriptionId,
      );
    }
    if (anySent) return const SmsServiceResult.ok();
    return SmsServiceResult.fail(firstErrorCode ?? 'SMS_SEND_FAILED');
  }

  /// Re-reads a group message's recipients, folds them into the one tick the
  /// bubble shows, writes that back and broadcasts it.
  ///
  /// The fold is deliberately pessimistic (see [GroupSendSummary]): a message
  /// three of four people got is not «ارسال شد».
  ///
  /// Returns the updated row, or null when [messageId] is not a group message.
  Future<MessageModel?> refreshGroupMessageStatus(
    String messageId, {
    DateTime? timestamp,
    int? subscriptionId,
  }) async {
    final row = await _messageRepository.getMessageById(messageId);
    if (row == null || !GroupThread.isGroup(row.threadId)) return null;
    final targets = await _groupRepository.targetsOf(messageId);
    if (targets.isEmpty) return null;
    final summary = GroupSendSummary.of(targets);
    final status = MessageStatus.values.firstWhere(
      (s) => s.name == summary.aggregateStatus,
      orElse: () => MessageStatus.sent,
    );
    final updated = row.copyWith(
      status: status,
      timestamp: timestamp,
      subscriptionId: subscriptionId,
    );
    // A targeted write, never a re-insert: `createMessage` REPLACEs, and the
    // unique content index would then delete somebody else's row to make room.
    await _messageRepository.applySendResult(updated);
    _statusController.add((
      messageId: messageId,
      status: status,
      replacement: updated,
    ));
    return updated;
  }

  /// «ارسال مجدد» on a bubble that failed.
  ///
  /// Re-sends the row that is already in the DB rather than composing a new
  /// one: the message keeps its id, its place in the conversation and its star,
  /// and a second failure updates the same bubble instead of stacking another.
  Future<SmsServiceResult> resendMessage(String messageId) async {
    final hasPermission = await requestPermissions();
    if (!hasPermission) {
      return const SmsServiceResult.fail('PERMISSION_DENIED');
    }
    final row = await _messageRepository.getMessageById(messageId);
    if (row == null || row.type != MessageType.sent) {
      return const SmsServiceResult.fail('SMS_SEND_FAILED');
    }
    // Already on its way (or already gone) — a double tap must not send twice.
    if (row.status != MessageStatus.failed) {
      return const SmsServiceResult.ok();
    }

    // A group message retries **only the recipients it failed for**. Re-sending
    // the whole group would text the people who already have it a second time.
    if (GroupThread.isGroup(row.threadId)) {
      final failed = [
        for (final target in await _groupRepository.targetsOf(messageId))
          if (target.failed) target,
      ];
      if (failed.isEmpty) return const SmsServiceResult.ok();
      for (final target in failed) {
        await _groupRepository.updateTarget(
          GroupSendTarget(
            messageId: target.messageId,
            phoneNumber: target.phoneNumber,
            status: 'pending',
            subscriptionId: target.subscriptionId,
            trackingId: target.trackingId,
          ),
        );
      }
      await refreshGroupMessageStatus(messageId);
      return _fanOut(row, failed);
    }
    final pending = row.copyWith(status: MessageStatus.pending);
    await _messageRepository.updateMessageStatus(
      messageId,
      MessageStatus.pending,
    );
    _statusController.add((
      messageId: messageId,
      status: MessageStatus.pending,
      replacement: pending,
    ));
    return _transmit(pending, alreadyStored: true);
  }

  /// Hands [pending] to the radio and writes the outcome back onto it.
  ///
  /// Shared by the first send, by «ارسال مجدد» and by the scheduled deliverer,
  /// so the three can never drift: one place decides what a successful send
  /// records and one place decides what a failure leaves behind.
  ///
  /// [alreadyStored] says whether the row is in the DB yet. False only on the
  /// non-optimistic (scheduled) path, where a failure must leave *nothing*
  /// behind and a success inserts the finished row in one go.
  Future<SmsServiceResult> _transmit(
    MessageModel pending, {
    required bool alreadyStored,
  }) async {
    Future<SmsServiceResult> fail(String code) async {
      if (!alreadyStored) return SmsServiceResult.fail(code);
      await _messageRepository.updateMessageStatus(
        pending.id,
        MessageStatus.failed,
      );
      _statusController.add((
        messageId: pending.id,
        status: MessageStatus.failed,
        replacement: pending.copyWith(status: MessageStatus.failed),
      ));
      return SmsServiceResult.fail(code);
    }

    try {
      final result = await _nativeSmsService.sendSms(
        phoneNumber: pending.phoneNumber,
        message: pending.body,
        subscriptionId: pending.subscriptionId,
        trackingId: pending.id,
        deliveryReport: deliveryReports,
      );

      // `await`ed on purpose: without it a DB write failing inside `fail`
      // escapes this try/catch.
      if (!result.success) return await fail('SMS_SEND_FAILED');

      final sent = pending.copyWith(
        status: MessageStatus.sent,
        timestamp: DateTime.fromMillisecondsSinceEpoch(result.timestamp),
        // Provider row id from the native write-through (default-SMS-app only)
        // so a later delete can remove the exact provider row.
        deviceSmsId: result.deviceId > 0 ? result.deviceId : null,
        // The SIM the send REALLY used: the native side resolves a null/-1
        // request to the system default before it writes the provider row, and
        // hands that back. Storing what was asked for instead would leave every
        // message sent without an explicit pick unlabelled.
        subscriptionId: result.subscriptionId >= 0
            ? result.subscriptionId
            : null,
      );
      if (alreadyStored) {
        await _messageRepository.applySendResult(sent);
      } else {
        await _messageRepository.createMessage(sent);
      }
      // Remember the card for this conversation — written on the send, not on
      // the pick, so it always reflects what actually went out.
      await _threadSimRepository.remember(sent.threadId, sent.subscriptionId);
      if (alreadyStored) {
        _statusController.add((
          messageId: sent.id,
          status: MessageStatus.sent,
          replacement: sent,
        ));
      } else {
        // Nothing has announced this row yet — the sent stream is what folds a
        // scheduled delivery into the open conversation.
        _sentController.add(sent);
      }
      return const SmsServiceResult.ok();
    } on PlatformException catch (e) {
      // Surface the native error code (NO_SIM_CARD, NO_SERVICE, etc.) directly
      // so the BLoC can show a localized message to the user.
      debugPrint('Platform error sending SMS: ${e.code} - ${e.message}');
      return fail(e.code);
    } catch (e) {
      debugPrint('Error sending SMS: $e');
      return fail('SMS_SEND_FAILED');
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

                // The address book is asked ONLY if it can answer from memory.
                //
                // This used to `await getContactByPhoneNumber`, and that is a
                // real, measurable delay on **received** messages — the one
                // the tester reported. A cold or invalidated contact cache
                // makes that call read the *whole* address book over a
                // platform channel, and `DeviceSyncQueue` serializes it behind
                // whatever heavy device read is already running: on resume
                // `MainNavigation` starts the SMS mirror-sync and the call-log
                // import, so a message arriving in that window waited for a
                // full provider walk before it was even written to SQLite,
                // never mind shown. Sending has no such step, which is exactly
                // why only received messages were late.
                //
                // Nothing is lost by skipping it. `contact_id` on a message row
                // is a convenience: the inbox and the conversation title
                // themselves from the device address book afterwards
                // (`MessageBloc._applyNames`, `ContactNameCache`), which is
                // also what lets a renamed or deleted contact reach a row that
                // was written long ago. A null here costs nothing visible.
                final contact = ContactRepository.cachedByPhoneNumber(
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
                  timestamp: DateTime.fromMillisecondsSinceEpoch(
                    event.timestamp,
                  ),
                  isRead: false, // New received messages are unread
                  // Which SIM took it. -1 is the platform's "unset" and must
                  // stay null: a wrong SIM badge is worse than none.
                  subscriptionId: event.subscriptionId >= 0
                      ? event.subscriptionId
                      : null,
                );

                await _messageRepository.createMessage(messageModel);
                // The arrival SIM of this conversation just changed hands;
                // drop the memo so the next reply is composed on it.
                ThreadSimRepository.invalidateIncoming(threadId);

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
              // A group send tags each recipient's PendingIntents with that
              // recipient's own tracking id, so a report may be about one member
              // of a group message rather than about a message row. Asked first:
              // the targets table is small and indexed on tracking_id, and a
              // group id can never collide with a message id (both are UUIDs
              // minted here).
              final groupMessageId = await _groupRepository.applyTargetStatus(
                event.id,
                status.name,
              );
              if (groupMessageId != null) {
                // Re-folds the recipients into the one tick the bubble shows and
                // broadcasts it — the whole group message, not this recipient.
                await refreshGroupMessageStatus(groupMessageId);
                return;
              }
              // A carrier report knows nothing but the new status, so it
              // carries no replacement row — the bloc copyWiths in place.
              await _messageRepository.updateMessageStatus(event.id, status);
              _statusController.add((
                messageId: event.id,
                status: status,
                replacement: null,
              ));
            });

            _listening = true;
          })
          .catchError((error) {
            debugPrint('Failed to initialize native SMS service: $error');
            // No plugin fallback: the manifest IncomingSmsReceiver still
            // persists + notifies natively, and the next app start retries
            // this initialization. (The old `another_telephony` fallback was
            // REMOVED — its global permission-result listener double-replied
            // a MethodChannel result and crashed the app whenever a telephony
            // call overlapped a permission dialog.)
          });
    } catch (e) {
      // Silently handle errors (e.g., permission denied)
      // SMS listening will be retried when permissions are granted
      debugPrint('Error setting up SMS listener: $e');
    }
  }

  /// How many provider rows are pulled over the MethodChannel at a time.
  ///
  /// The full rows travel as one payload, so an unbounded read could exceed the
  /// Binder transaction limit (~1 MB) on a large mailbox. This is a *page*
  /// size, not a cap on what gets imported: the sync pages until nothing is
  /// missing.
  ///
  /// It used to be a hard cap of 500 rows per box, and that is exactly why
  /// older conversations showed only the user's own half. A real phone receives
  /// far more than it sends — bank codes, delivery notices, promotions — so 500
  /// inbox rows reached about six weeks back while 500 sent rows reached a
  /// year: every conversation older than that kept its sent bubbles and lost
  /// every received one.
  static const int _importPageSize = 200;

  /// Mirror-syncs the local message store with the device SMS provider:
  ///
  /// 1. The provider's id list (inbox + sent, newest first) is diffed against
  ///    the ids the local store already knows, and **only the missing rows**
  ///    are read — paged, so a mailbox of any size is covered without a single
  ///    oversized payload. New messages are imported and rows the app already
  ///    has get their `device_sms_id` linked (see
  ///    [MessageRepository.reconcileDeviceRows]).
  /// 2. Local rows whose provider row disappeared are removed — a message
  ///    deleted on the phone (by another SMS app, or before this app held the
  ///    default role) disappears here too.
  ///
  /// Runs on every app session start and on resume. The steady state costs two
  /// id queries and nothing else: with no missing ids there is no content read
  /// at all, which is cheaper than the old "re-read the newest 500 rows of each
  /// box every time" and, unlike it, actually finishes the mailbox.
  ///
  /// [onProgress] is called after each imported page, so a long first import
  /// can show the newest conversations while the older ones are still arriving.
  Future<void> syncDeviceMessages({
    bool forceRefresh = false,
    bool throttle = false,
    void Function()? onProgress,
  }) async {
    // Collapse resume-storm syncs: skip a silent resume sync that lands within
    // the throttle window of the previous one. forceRefresh never throttles.
    if (throttle && !forceRefresh) {
      final last = _lastSyncAt;
      if (last != null &&
          DateTime.now().difference(last) < _resumeSyncThrottle) {
        return;
      }
    }

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

    // ── 1. Which rows are missing ──────────────────────────────────────────
    // Ids only: a tiny payload even for a mailbox of tens of thousands, and it
    // answers both halves of the sync — what to import and what to delete.
    final inboxIds = await _nativeSmsService.querySmsIds(box: 'inbox');
    final sentIds = await _nativeSmsService.querySmsIds(box: 'sent');
    final known = await _messageRepository.knownDeviceSmsIds([
      ...inboxIds,
      ...sentIds,
    ]);

    // ── 2. Read and reconcile only those, newest first ─────────────────────
    // Queued so this doesn't hold a page of SMS rows in memory at the same
    // moment the contacts and call-log imports hold theirs.
    Future<void> importMissing(
      String box,
      List<int> ids,
      MessageType type,
    ) async {
      final missing = [
        for (final id in ids)
          if (!known.contains(id)) id,
      ];
      for (var i = 0; i < missing.length; i += _importPageSize) {
        final end = i + _importPageSize > missing.length
            ? missing.length
            : i + _importPageSize;
        final page = missing.sublist(i, end);
        final rows = await DeviceSyncQueue.run(
          () => _nativeSmsService.querySmsByIds(box: box, ids: page),
        );
        if (rows.isEmpty) continue;
        await _messageRepository.reconcileDeviceRows([
          for (final row in rows) _createMessageModel(row, type, contactMap),
        ]);
        // Let the UI isolate breathe between pages — a first import walks the
        // whole mailbox and must never hold the frame.
        await Future.delayed(Duration.zero);
        onProgress?.call();
      }
    }

    await importMissing('inbox', inboxIds, MessageType.received);
    await importMissing('sent', sentIds, MessageType.sent);

    // Imported rows carry the SIM the provider stamped them with, so anything
    // memoized about which card a conversation arrives on is now a guess made
    // from less data.
    ThreadSimRepository.clearIncoming();

    // ── 3. Remove local rows deleted on the device ─────────────────────────
    // A local row linked to a provider id that is in neither box no longer
    // exists on the device.
    final deviceIds = <int>{...inboxIds, ...sentIds};
    // Safety: an empty id set means the query failed (or the provider is
    // genuinely empty, in which case there is nothing to lose by waiting for
    // the next pass) — do NOT wipe the local mirror on a transient read error.
    if (deviceIds.isEmpty) return;
    final removed = await _messageRepository.removeRowsMissingFromDevice(
      deviceIds,
    );
    if (removed > 0) {
      debugPrint('Device mirror-sync removed $removed locally-stale messages');
    }

    // Stamp only on a full, successful pass — NOT on the transient-failure
    // early return above — so a failed read retries on the next resume.
    _lastSyncAt = DateTime.now();
  }

  MessageModel _createMessageModel(
    DeviceSmsRow row,
    MessageType type,
    Map<String, dynamic> contactMap,
  ) {
    final phone = row.address;
    final normalized = _normalizePhoneNumber(phone);
    final threadId = normalized.isNotEmpty ? normalized : phone;
    final contact = contactMap[normalized];
    final status = type == MessageType.sent
        ? MessageStatus.sent
        : MessageStatus.delivered;

    return MessageModel(
      id: row.id.toString(),
      threadId: threadId,
      contactId: contact?.id,
      phoneNumber: phone,
      body: row.body,
      type: type,
      status: status,
      timestamp: DateTime.fromMillisecondsSinceEpoch(
        row.date > 0 ? row.date : DateTime.now().millisecondsSinceEpoch,
      ),
      // Imported messages from device are considered already read
      isRead: true,
      // Provider row id — the key the mirror-sync diffs on.
      deviceSmsId: row.id,
      // The provider is authoritative about which SIM carried a message; null
      // when it never stamped the row, which stays "unknown" rather than
      // becoming a guessed SIM 1.
      subscriptionId: row.subscriptionId,
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

    // A group message is one row but N provider rows, and its own
    // `device_sms_id` is deliberately NULL — so its ids are read from
    // `message_group_targets` and deleted by id. Falling through to the
    // body+timestamp fallback would work by accident and delete by content
    // across every address in a ±10 s window, which is not something to leave to
    // luck in the default SMS app.
    final groupIds = [
      for (final m in messages)
        if (GroupThread.isGroup(m.threadId)) m.id,
    ];
    final groupTargets = await _groupRepository.targetsForMessages(groupIds);

    final specs = <Map<String, Object?>>[];
    for (final m in messages) {
      if (GroupThread.isGroup(m.threadId)) {
        for (final target in groupTargets[m.id] ?? const []) {
          if (target.deviceSmsId != null) {
            specs.add({'deviceId': target.deviceSmsId});
          }
        }
        continue;
      }
      specs.add(
        m.deviceSmsId != null
            ? {'deviceId': m.deviceSmsId}
            : {'body': m.body, 'timestamp': m.timestamp.millisecondsSinceEpoch},
      );
    }
    await _nativeSmsService.deleteSmsFromProvider(specs);
    // Soft, as always: the target rows keep their `device_sms_id`s and the
    // message row keeps its tombstone, so a provider delete the app was not
    // allowed to make (not the default SMS app) does not resurrect on the next
    // mirror-sync.
    await _messageRepository.softDeleteMessages(messageIds);
  }

  /// Deletes a whole conversation globally: every provider row for the thread
  /// address (default-SMS-app only), then the local thread.
  ///
  /// The local half is a **soft** delete on purpose. A hard delete drops the
  /// `device_sms_id` tombstones, and then anything the provider delete missed —
  /// it is a no-op unless this app holds the SMS role, and it matches addresses
  /// by their last 10 digits — is re-imported by the next mirror-sync and the
  /// whole conversation reappears (typically after an app restart).
  Future<void> deleteThreadGlobally(String threadId) async {
    // A group thread id is not an address, so there is no provider conversation
    // to delete by address: the rows it produced are named one by one from
    // `message_group_targets`. The group itself goes too — leaving the shell of
    // a deleted conversation behind would put it back in the inbox the moment
    // anything was sent to it.
    if (GroupThread.isGroup(threadId)) {
      final ids = await _groupRepository.deviceSmsIdsForThread(threadId);
      if (ids.isNotEmpty) {
        await _nativeSmsService.deleteSmsFromProvider([
          for (final id in ids) {'deviceId': id},
        ]);
      }
      // Soft, so the target rows stay valid tombstones for the mirror-sync.
      await _messageRepository.softDeleteThread(threadId);
      final groupId = GroupThread.groupIdOf(threadId);
      if (groupId != null) await _groupRepository.delete(groupId);
      return;
    }
    // threadId IS the normalized national number — usable as the address key.
    await _nativeSmsService.deleteSmsThreadFromProvider(threadId);
    await _messageRepository.softDeleteThread(threadId);
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
