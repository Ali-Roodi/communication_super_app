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

  const SendMessage({required this.phoneNumber, required this.body});

  @override
  List<Object?> get props => [phoneNumber, body];
}

class ReceiveMessage extends MessageEvent {
  final MessageModel message;

  const ReceiveMessage(this.message);

  @override
  List<Object?> get props => [message];
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
