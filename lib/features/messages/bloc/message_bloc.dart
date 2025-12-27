import 'package:flutter_bloc/flutter_bloc.dart';
import 'message_event.dart';
import 'message_state.dart';
import '../repositories/message_repository.dart';
import '../services/sms_service.dart';

class MessageBloc extends Bloc<MessageEvent, MessageState> {
  final MessageRepository _repository = MessageRepository();
  final SmsService _smsService = SmsService();
  static bool _hasImported = false;

  MessageBloc() : super(const MessageInitial()) {
    on<LoadThreads>(_onLoadThreads);
    on<LoadMessages>(_onLoadMessages);
    on<SendMessage>(_onSendMessage);
    on<ReceiveMessage>(_onReceiveMessage);
    on<DeleteMessage>(_onDeleteMessage);
    on<DeleteThread>(_onDeleteThread);

    // Set up SMS listener callback
    _smsService.onMessageReceived = (message) {
      add(ReceiveMessage(message));
    };
    
    // Initialize SMS listening (non-blocking, won't throw)
    // This will only work when SMS permissions are granted
    try {
      _smsService.listenToIncomingSms();
    } catch (e) {
      // Ignore initialization errors - SMS listening can be retried later
      // when permissions are granted or when the messages screen is opened
    }
  }

  Future<void> _onLoadThreads(
    LoadThreads event,
    Emitter<MessageState> emit,
  ) async {
    emit(const MessageLoading());
    try {
      // Import device messages only once per app session (or on explicit force)
      if (!_hasImported || event.forceRefresh) {
        await _smsService.importDeviceMessages(forceRefresh: event.forceRefresh);
        _hasImported = true;
      }

      final threads = await _repository.getAllThreads();
      emit(ThreadsLoaded(threads));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onLoadMessages(
    LoadMessages event,
    Emitter<MessageState> emit,
  ) async {
    emit(const MessageLoading());
    try {
      final messages = await _repository.getMessagesByThread(event.threadId);
      emit(MessagesLoaded(messages));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      final success = await _smsService.sendSms(
        event.phoneNumber,
        event.body,
      );
      if (success) {
        emit(const MessageSent());
        add(const LoadThreads());
        final threadId = event.phoneNumber;
        add(LoadMessages(threadId));
      } else {
        emit(const MessageError('Failed to send message'));
      }
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onReceiveMessage(
    ReceiveMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      await _repository.createMessage(event.message);
      add(const LoadThreads());
      if (state is MessagesLoaded) {
        final currentState = state as MessagesLoaded;
        if (currentState.messages.isNotEmpty &&
            currentState.messages.first.threadId == event.message.threadId) {
          add(LoadMessages(event.message.threadId));
        }
      }
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onDeleteMessage(
    DeleteMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      await _repository.deleteMessage(event.messageId);
      add(const LoadThreads());
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onDeleteThread(
    DeleteThread event,
    Emitter<MessageState> emit,
  ) async {
    try {
      await _repository.deleteThread(event.threadId);
      add(const LoadThreads());
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }
}


