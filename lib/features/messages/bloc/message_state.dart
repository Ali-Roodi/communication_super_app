import 'package:equatable/equatable.dart';
import '../models/message_model.dart';

abstract class MessageState extends Equatable {
  const MessageState();

  @override
  List<Object?> get props => [];
}

class MessageInitial extends MessageState {
  const MessageInitial();
}

class MessageLoading extends MessageState {
  const MessageLoading();
}

class ThreadsLoaded extends MessageState {
  final List<MessageThread> threads;
  final bool hasMore;

  /// Whether these are archived conversations (archived view) or the inbox.
  final bool archived;

  /// The device mirror-sync is still walking the provider.
  ///
  /// Only interesting while the list is **empty**: on a first install the local
  /// store is empty and the import takes as long as the mailbox is big, so
  /// without this the inbox confidently says «هیچ پیامی ندارید» over a phone
  /// full of messages for the whole import.
  final bool syncing;

  const ThreadsLoaded(
    this.threads, {
    this.hasMore = false,
    this.archived = false,
    this.syncing = false,
  });

  @override
  List<Object?> get props => [threads, hasMore, archived, syncing];
}

class MessagesLoaded extends MessageState {
  final List<MessageModel> messages;
  final bool hasMore;

  /// Thread id for the open conversation (needed to append incoming messages in-place).
  final String threadId;

  const MessagesLoaded(
    this.messages, {
    this.hasMore = false,
    required this.threadId,
  });

  @override
  List<Object?> get props => [threadId, messages, hasMore];
}

class MessageSent extends MessageState {
  const MessageSent();
}

/// Emitted when SMS sending fails.  Carries a typed [errorCode] so the UI can
/// show an appropriate localized message without replacing the conversation.
class MessageSendFailed extends MessageState {
  /// One of: 'NO_SIM_CARD', 'NO_SERVICE', 'PERMISSION_DENIED', 'SMS_SEND_FAILED'
  final String errorCode;
  final String userMessage;

  const MessageSendFailed({required this.errorCode, required this.userMessage});

  @override
  List<Object?> get props => [errorCode, userMessage];
}

class MessageError extends MessageState {
  final String message;

  const MessageError(this.message);

  @override
  List<Object?> get props => [message];
}
