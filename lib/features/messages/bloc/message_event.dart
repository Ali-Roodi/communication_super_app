import 'package:equatable/equatable.dart';
import '../models/message_model.dart';

abstract class MessageEvent extends Equatable {
  const MessageEvent();

  @override
  List<Object?> get props => [];
}

class LoadThreads extends MessageEvent {
  const LoadThreads();
}

class LoadMessages extends MessageEvent {
  final String threadId;

  const LoadMessages(this.threadId);

  @override
  List<Object?> get props => [threadId];
}

class SendMessage extends MessageEvent {
  final String phoneNumber;
  final String body;

  const SendMessage({
    required this.phoneNumber,
    required this.body,
  });

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









