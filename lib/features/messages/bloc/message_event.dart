import 'package:equatable/equatable.dart';
import '../models/message_model.dart';

abstract class MessageEvent extends Equatable {
  const MessageEvent();

  @override
  List<Object?> get props => [];
}

class LoadThreads extends MessageEvent {
  final bool forceRefresh;
  final int limit;
  final int offset;

  /// When true, loads the archived inbox instead of the active one.
  final bool archived;

  const LoadThreads({
    this.forceRefresh = false,
    this.limit = 50,
    this.offset = 0,
    this.archived = false,
  });

  @override
  List<Object?> get props => [forceRefresh, limit, offset, archived];
}

/// Rebuild the phone→name cache from the (refreshed) device contacts and
/// re-resolve names on the currently loaded threads. Dispatched when the device
/// address book changes, so a newly-saved contact's name shows without a
/// full reload.
class RefreshContactNames extends MessageEvent {
  const RefreshContactNames();
}

class LoadMoreThreads extends MessageEvent {
  const LoadMoreThreads();
}

/// Silent mirror-sync with the device SMS provider (import new rows, drop
/// device-deleted ones) followed by an in-place refresh — no loading state.
/// Dispatched on app resume so changes made while backgrounded show up.
class SyncDeviceMessages extends MessageEvent {
  const SyncDeviceMessages();
}

/// A background mirror-sync finished. Dispatched by the bloc itself once the
/// sync future it started off the event queue completes, so the refresh that
/// folds the synced rows in runs as a normal (short) event instead of the sync
/// itself blocking every other event behind it.
class DeviceSyncFinished extends MessageEvent {
  final bool ok;

  const DeviceSyncFinished({required this.ok});

  @override
  List<Object?> get props => [ok];
}

class LoadMessages extends MessageEvent {
  final String threadId;
  final int limit;
  final int offset;

  const LoadMessages(this.threadId, {this.limit = 50, this.offset = 0});

  @override
  List<Object?> get props => [threadId, limit, offset];
}

class LoadMoreMessages extends MessageEvent {
  final String threadId;

  const LoadMoreMessages(this.threadId);

  @override
  List<Object?> get props => [threadId];
}

class SendMessage extends MessageEvent {
  final String phoneNumber;
  final String body;

  /// SIM to send on. Null = the platform's default, which is the only correct
  /// answer on a single-SIM phone and on a dual-SIM one with a pinned default.
  final int? subscriptionId;

  const SendMessage({
    required this.phoneNumber,
    required this.body,
    this.subscriptionId,
  });

  @override
  List<Object?> get props => [phoneNumber, body, subscriptionId];
}

class ReceiveMessage extends MessageEvent {
  final MessageModel message;

  const ReceiveMessage(this.message);

  @override
  List<Object?> get props => [message];
}

/// An outgoing message was persisted by *some* code path (composer, scheduled
/// delivery, "send now"). Appends it to the open conversation or refreshes the
/// inbox, exactly like [ReceiveMessage] does for incoming ones.
class MessageSentExternally extends MessageEvent {
  final MessageModel message;

  const MessageSentExternally(this.message);

  @override
  List<Object?> get props => [message];
}

/// A delivery report arrived for an outgoing message (sent → delivered or
/// failed). The DB row is already updated by SmsService; this only refreshes
/// the open conversation's bubble tick.
class MessageStatusChanged extends MessageEvent {
  final String messageId;
  final MessageStatus status;

  /// The full row, when the change brought more than a status with it — the
  /// send result also learns the provider row id, the SIM the radio really
  /// used and the moment it was accepted. Null for a carrier delivery report,
  /// which knows nothing but the new status.
  final MessageModel? replacement;

  const MessageStatusChanged(this.messageId, this.status, {this.replacement});

  @override
  List<Object?> get props => [messageId, status, replacement];
}

/// «ارسال مجدد» on a bubble that failed (airplane mode, no service …).
///
/// Re-sends the row already in the DB — same id, same place in the thread — so
/// a retry updates that bubble instead of adding another next to it.
class RetryMessage extends MessageEvent {
  final String messageId;

  const RetryMessage(this.messageId);

  @override
  List<Object?> get props => [messageId];
}

class DeleteMessage extends MessageEvent {
  final String messageId;

  const DeleteMessage(this.messageId);

  @override
  List<Object?> get props => [messageId];
}

class DeleteThread extends MessageEvent {
  final String threadId;

  const DeleteThread(this.threadId);

  @override
  List<Object?> get props => [threadId];
}

/// Bulk hard-delete of whole conversations (multi-select).
class DeleteThreads extends MessageEvent {
  final List<String> threadIds;

  const DeleteThreads(this.threadIds);

  @override
  List<Object?> get props => [threadIds];
}

/// Bulk soft-delete of individual messages inside the open conversation.
class DeleteMessages extends MessageEvent {
  final String threadId;
  final List<String> messageIds;

  const DeleteMessages(this.threadId, this.messageIds);

  @override
  List<Object?> get props => [threadId, messageIds];
}

/// Archive / unarchive one or more conversations. Reloads the appropriate
/// inbox afterwards (active vs. archived view, per [fromArchivedView]).
class ArchiveThreads extends MessageEvent {
  final List<String> threadIds;
  final bool archive;
  final bool fromArchivedView;

  const ArchiveThreads(
    this.threadIds, {
    this.archive = true,
    this.fromArchivedView = false,
  });

  @override
  List<Object?> get props => [threadIds, archive, fromArchivedView];
}

/// Pin / unpin a conversation (single, from the long-press sheet).
class PinThread extends MessageEvent {
  final String threadId;
  final bool pin;

  const PinThread(this.threadId, {this.pin = true});

  @override
  List<Object?> get props => [threadId, pin];
}

/// Mark a conversation read / unread.
class SetThreadRead extends MessageEvent {
  final List<String> threadIds;
  final bool read;

  const SetThreadRead(this.threadIds, {this.read = true});

  @override
  List<Object?> get props => [threadIds, read];
}
