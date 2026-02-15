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

  const ThreadsLoaded(this.threads, {this.hasMore = false});

  @override
  List<Object?> get props => [threads, hasMore];
}

class MessagesLoaded extends MessageState {
  final List<MessageModel> messages;
  final bool hasMore;
  /// Thread id for the open conversation (needed to append incoming messages in-place).
  final String threadId;

  const MessagesLoaded(this.messages, {this.hasMore = false, required this.threadId});

  @override
  List<Object?> get props => [threadId, messages, hasMore];
}

class MessageSent extends MessageState {
  const MessageSent();
}

class MessageError extends MessageState {
  final String message;

  const MessageError(this.message);

  @override
  List<Object?> get props => [message];
}
























