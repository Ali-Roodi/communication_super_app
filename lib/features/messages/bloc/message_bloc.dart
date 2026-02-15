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
    on<LoadMoreThreads>(_onLoadMoreThreads);
    on<LoadMessages>(_onLoadMessages);
    on<LoadMoreMessages>(_onLoadMoreMessages);
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
    // Only emit loading when we're not already showing threads or conversation.
    // This prevents the chat screen from going black when an incoming SMS triggers
    // a background thread refresh (e.g. user on conversation for another thread).
    if (state is! ThreadsLoaded && state is! MessagesLoaded) {
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
          final threads = await _repository.getAllThreads(limit: 50, offset: 0);
          if (threads.isEmpty) {
            emit(MessageError('دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.'));
            return;
          }
        }
      }

      final limit = event.limit;
      final offset = event.offset;
      final threads = await _repository.getAllThreads(limit: limit, offset: offset);
      emit(ThreadsLoaded(
        threads,
        hasMore: threads.length >= limit,
      ));
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
    if (state is! MessagesLoaded) {
      emit(const MessageLoading());
    }
    try {
      await _repository.markThreadAsRead(event.threadId);
      // Load latest messages first (DESC), then reverse for chronological order
      final messages = await _repository.getMessagesByThread(
        event.threadId,
        limit: event.limit,
        offset: event.offset,
        orderDesc: true,
      );
      final chronological = messages.reversed.toList();
      emit(MessagesLoaded(
        chronological,
        hasMore: messages.length >= event.limit,
        threadId: event.threadId,
      ));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onLoadMoreThreads(
    LoadMoreThreads event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is! ThreadsLoaded || !current.hasMore) return;
    try {
      final more = await _repository.getAllThreads(
        limit: 50,
        offset: current.threads.length,
      );
      if (more.isEmpty) {
        emit(ThreadsLoaded(current.threads, hasMore: false));
        return;
      }
      emit(ThreadsLoaded(
        [...current.threads, ...more],
        hasMore: more.length >= 50,
      ));
    } catch (_) {
      emit(ThreadsLoaded(current.threads, hasMore: false));
    }
  }

  Future<void> _onLoadMoreMessages(
    LoadMoreMessages event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is! MessagesLoaded || !current.hasMore) return;
    try {
      final older = await _repository.getMessagesByThread(
        event.threadId,
        limit: 50,
        offset: current.messages.length,
        orderDesc: true,
      );
      if (older.isEmpty) {
        emit(MessagesLoaded(current.messages, hasMore: false, threadId: current.threadId));
        return;
      }
      final chronologicalOlder = older.reversed.toList();
      emit(MessagesLoaded(
        [...chronologicalOlder, ...current.messages],
        hasMore: older.length >= 50,
        threadId: current.threadId,
      ));
    } catch (_) {
      emit(MessagesLoaded(current.messages, hasMore: false, threadId: current.threadId));
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
      // Message is already created in SmsService before this callback; do not insert again.
      final current = state;
      if (current is MessagesLoaded) {
        if (current.threadId == event.message.threadId) {
          // Dedupe: avoid appending if this message is already in the list (e.g. duplicate event).
          final alreadyPresent = current.messages.any((m) =>
              m.id == event.message.id ||
              (m.body == event.message.body &&
                  m.timestamp == event.message.timestamp &&
                  m.phoneNumber == event.message.phoneNumber));
          if (!alreadyPresent) {
            emit(MessagesLoaded(
              [...current.messages, event.message],
              hasMore: current.hasMore,
              threadId: current.threadId,
            ));
          }
        }
        // Else: different thread; do not dispatch LoadThreads so we don't replace state with ThreadsLoaded.
      } else {
        // Not on conversation screen: refresh thread list (won't emit loading due to _onLoadThreads guard).
        add(const LoadThreads());
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


