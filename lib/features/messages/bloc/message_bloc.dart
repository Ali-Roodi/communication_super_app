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
    
    // NOTE: SMS listening will be initialized only after permissions are granted
    // and when LoadThreads event is first triggered (in _onLoadThreads)
  }

  Future<void> _onLoadThreads(
    LoadThreads event,
    Emitter<MessageState> emit,
  ) async {
    // Only emit loading if we're not already in ThreadsLoaded state
    // This prevents the loading spinner from showing when returning from conversation
    if (state is! ThreadsLoaded) {
      emit(const MessageLoading());
    }
    
    try {
      // Import device messages only once per app session (or on explicit force)
      if (!_hasImported || event.forceRefresh) {
        try {
        await _smsService.importDeviceMessages(forceRefresh: event.forceRefresh);
        _hasImported = true;
        
        // Initialize SMS listening only after successful import (permissions granted)
        try {
          _smsService.listenToIncomingSms();
        } catch (e) {
          // Silently fail - SMS listening is not critical for basic functionality
        }
        } catch (importError) {
          // If import fails (e.g., permissions denied), continue to show local messages
          // but emit error if there are no local messages
          final threads = await _repository.getAllThreads();
          if (threads.isEmpty) {
            emit(MessageError('دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.'));
            return;
          }
        }
      }

      final threads = await _repository.getAllThreads();
      emit(ThreadsLoaded(threads));
    } catch (e) {
      final errorMessage = e.toString().contains('Permission') 
          ? 'دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.'
          : 'خطا در بارگذاری پیام‌ها: ${e.toString()}';
      emit(MessageError(errorMessage));
    }
  }

  Future<void> _onLoadMessages(
    LoadMessages event,
    Emitter<MessageState> emit,
  ) async {
    // Only emit loading if we're not already in MessagesLoaded state
    // This prevents blank screen when sending messages or receiving updates
    if (state is! MessagesLoaded) {
      emit(const MessageLoading());
    }
    
    try {
      // Mark all messages in this thread as read
      await _repository.markThreadAsRead(event.threadId);
      
      // Load messages
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
        // Do not automatically reload threads or messages here
        // Let the UI screens decide what to reload based on their context
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


