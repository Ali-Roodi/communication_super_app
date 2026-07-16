import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'message_event.dart';
import 'message_state.dart';
import '../repositories/message_repository.dart';
import '../services/sms_service.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import '../models/message_model.dart';

class MessageBloc extends Bloc<MessageEvent, MessageState> {
  final MessageRepository _repository;
  final SmsService _smsService;
  final ContactRepository _contactRepository;
  static bool _hasImported = false;

  /// One-per-session cache of the normalized-number → contact name lookup table.
  ///
  /// Building this map requires fetching all device contacts (which is slow on
  /// the first call but fast once the ContactRepository cache is warm).
  /// Caching it here avoids re-fetching on every LoadThreads dispatch
  /// (e.g., on app resume, on tab switch, after sending a message).
  Map<String, String>? _cachedPhoneToName;

  /// Dependencies default to real implementations so production callers can use
  /// `MessageBloc()`; tests can inject fakes/mocks.
  MessageBloc({
    MessageRepository? repository,
    SmsService? smsService,
    ContactRepository? contactRepository,
  }) : _repository = repository ?? MessageRepository(),
       _smsService = smsService ?? SmsService(),
       _contactRepository = contactRepository ?? ContactRepository(),
       super(const MessageInitial()) {
    on<LoadThreads>(_onLoadThreads);
    on<SyncDeviceMessages>(_onSyncDeviceMessages);
    on<LoadMoreThreads>(_onLoadMoreThreads);
    on<LoadMessages>(_onLoadMessages);
    on<LoadMoreMessages>(_onLoadMoreMessages);
    on<SendMessage>(_onSendMessage);
    on<ReceiveMessage>(_onReceiveMessage);
    on<MessageSentExternally>(_onMessageSentExternally);
    on<RefreshContactNames>(_onRefreshContactNames);
    on<DeleteMessage>(_onDeleteMessage);
    on<DeleteThread>(_onDeleteThread);
    on<DeleteThreads>(_onDeleteThreads);
    on<DeleteMessages>(_onDeleteMessages);
    on<ArchiveThreads>(_onArchiveThreads);
    on<PinThread>(_onPinThread);
    on<SetThreadRead>(_onSetThreadRead);

    // Set up SMS listener callback
    _smsService.onMessageReceived = (message) {
      add(ReceiveMessage(message));
    };

    // Outgoing messages can be persisted by code that doesn't go through this
    // bloc (the scheduled-message deliverer). Mirror them into the UI too.
    _sentSubscription = SmsService.onMessageSent.listen(
      (message) => add(MessageSentExternally(message)),
    );

    // NOTE: SMS listening will be initialized only after permissions are granted
    // and when LoadThreads event is first triggered (in _onLoadThreads)
  }

  StreamSubscription<MessageModel>? _sentSubscription;

  @override
  Future<void> close() {
    _sentSubscription?.cancel();
    return super.close();
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
      // Mirror-sync with the device provider once per app session (or on
      // explicit force). Resume-time syncs go through SyncDeviceMessages.
      if (!_hasImported || event.forceRefresh) {
        try {
          await _smsService.syncDeviceMessages(
            forceRefresh: event.forceRefresh,
          );
          _hasImported = true;

          // Start the SMS listener only once: the SmsService._listening guard
          // makes subsequent calls no-ops, but we also avoid unnecessary calls
          // so that the EventChannel is never torn down and rebuilt (which would
          // create a window where incoming messages are dropped).
          if (!_smsService.isListening) {
            try {
              _smsService.listenToIncomingSms();
            } catch (e) {
              // Silently fail - SMS listening is not critical for basic functionality
            }
          }
        } catch (importError) {
          // If import fails (e.g., permissions denied), continue to show local messages
          // but emit error if there are no local messages
          final threads = await _repository.getAllThreads(limit: 50, offset: 0);
          if (threads.isEmpty) {
            emit(
              MessageError(
                'دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.',
              ),
            );
            return;
          }
        }
      }

      final limit = event.limit;
      final offset = event.offset;
      final rawThreads = await _repository.getAllThreads(
        limit: limit,
        offset: offset,
        archived: event.archived,
      );
      final threads = await _resolveContactNames(rawThreads);
      emit(
        ThreadsLoaded(
          threads,
          hasMore: threads.length >= limit,
          archived: event.archived,
        ),
      );
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
      emit(
        MessagesLoaded(
          chronological,
          hasMore: messages.length >= event.limit,
          threadId: event.threadId,
        ),
      );
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  /// Silent device mirror-sync + in-place refresh (no loading state, no
  /// flicker). Runs on app resume: messages may have been sent/deleted on the
  /// device while this app was backgrounded.
  Future<void> _onSyncDeviceMessages(
    SyncDeviceMessages event,
    Emitter<MessageState> emit,
  ) async {
    try {
      await _smsService.syncDeviceMessages();
    } catch (_) {
      return; // No permission / transient failure — keep what's on screen.
    }
    final current = state;
    try {
      if (current is MessagesLoaded) {
        // A conversation is open: refresh its bubbles in place.
        final limit = current.messages.length > 50
            ? current.messages.length
            : 50;
        final messages = await _repository.getMessagesByThread(
          current.threadId,
          limit: limit,
          offset: 0,
          orderDesc: true,
        );
        emit(
          MessagesLoaded(
            messages.reversed.toList(),
            hasMore: messages.length >= limit,
            threadId: current.threadId,
          ),
        );
      } else if (current is ThreadsLoaded) {
        final limit = current.threads.length > 50 ? current.threads.length : 50;
        final rawThreads = await _repository.getAllThreads(
          limit: limit,
          offset: 0,
          archived: current.archived,
        );
        final threads = await _resolveContactNames(rawThreads);
        emit(
          ThreadsLoaded(
            threads,
            hasMore: threads.length >= limit,
            archived: current.archived,
          ),
        );
      }
    } catch (_) {
      // Silent by design.
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
        archived: current.archived,
      );
      if (more.isEmpty) {
        emit(
          ThreadsLoaded(
            current.threads,
            hasMore: false,
            archived: current.archived,
          ),
        );
        return;
      }
      final resolved = await _resolveContactNames(more);
      emit(
        ThreadsLoaded(
          [...current.threads, ...resolved],
          hasMore: more.length >= 50,
          archived: current.archived,
        ),
      );
    } catch (_) {
      emit(
        ThreadsLoaded(
          current.threads,
          hasMore: false,
          archived: current.archived,
        ),
      );
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
        emit(
          MessagesLoaded(
            current.messages,
            hasMore: false,
            threadId: current.threadId,
          ),
        );
        return;
      }
      final chronologicalOlder = older.reversed.toList();
      emit(
        MessagesLoaded(
          [...chronologicalOlder, ...current.messages],
          hasMore: older.length >= 50,
          threadId: current.threadId,
        ),
      );
    } catch (_) {
      emit(
        MessagesLoaded(
          current.messages,
          hasMore: false,
          threadId: current.threadId,
        ),
      );
    }
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      final result = await _smsService.sendSms(event.phoneNumber, event.body);
      if (result.success) {
        emit(const MessageSent());
        // Let the UI screens decide what to reload based on their context.
      } else {
        emit(
          MessageSendFailed(
            errorCode: result.errorCode ?? 'SMS_SEND_FAILED',
            userMessage: _localizedSendError(result.errorCode),
          ),
        );
      }
    } catch (e) {
      emit(
        MessageSendFailed(
          errorCode: 'SMS_SEND_FAILED',
          userMessage: _localizedSendError(null),
        ),
      );
    }
  }

  /// Enriches [threads] with contact names looked up from the device contacts
  /// cache (ContactRepository).
  ///
  /// The app's local `contacts` DB table is only populated for contacts that
  /// the user has manually saved through the app; device contacts are held in
  /// an in-memory cache.  The SQL LEFT JOIN in getAllThreads() therefore often
  /// returns null for contact_name.  This post-load pass fills the gap without
  /// a DB schema change.
  ///
  /// The phone-to-name map is built ONCE per app session and reused for all
  /// subsequent calls.  This avoids the O(contacts) fetch on every LoadThreads
  /// dispatch (tab switch, app resume, new message arrived, etc.).
  Future<List<MessageThread>> _resolveContactNames(
    List<MessageThread> threads,
  ) async {
    if (threads.isEmpty) return threads;
    try {
      // Build (or reuse) the cached lookup map.
      if (_cachedPhoneToName == null) {
        final contacts = await _contactRepository.getAllContacts();
        final map = <String, String>{};
        for (final c in contacts) {
          if (c.name.isEmpty) continue;
          for (final phone in [...c.phoneNumbers, c.phoneNumber]) {
            // Key on the normalized national number (09xxxxxxxxx) so a contact
            // saved as 0912… still matches an incoming SMS whose address is the
            // E.164 form (+98912…). Keying on raw digits missed those.
            final key = PhoneNormalizer.toThreadId(phone);
            if (key.isNotEmpty) map[key] = c.name;
          }
        }
        _cachedPhoneToName = map;
      }

      final phoneToName = _cachedPhoneToName!;
      if (phoneToName.isEmpty) return threads;

      return threads.map((t) {
        if (t.contactName != null && t.contactName!.isNotEmpty) return t;
        final name = phoneToName[PhoneNormalizer.toThreadId(t.phoneNumber)];
        if (name == null || name.isEmpty) return t;
        return t.copyWith(contactName: name);
      }).toList();
    } catch (_) {
      return threads;
    }
  }

  /// Maps a native error code to a user-facing Persian string.
  static String _localizedSendError(String? code) {
    switch (code) {
      case 'NO_SIM_CARD':
        return 'سیم‌کارتی در دستگاه یافت نشد.';
      case 'NO_SERVICE':
        return 'سرویس شبکه در دسترس نیست. لطفاً اتصال شبکه را بررسی کنید.';
      case 'PERMISSION_DENIED':
        return 'دسترسی به ارسال پیامک رد شد. لطفاً مجوزهای لازم را بررسی کنید.';
      default:
        return 'خطا در ارسال پیامک. لطفاً مجدداً تلاش کنید.';
    }
  }

  Future<void> _onReceiveMessage(
    ReceiveMessage event,
    Emitter<MessageState> emit,
  ) async => _mergePersistedMessage(event.message, emit);

  Future<void> _onMessageSentExternally(
    MessageSentExternally event,
    Emitter<MessageState> emit,
  ) async => _mergePersistedMessage(event.message, emit);

  /// Folds a message that is *already in the DB* into the current state: append
  /// it to the open conversation, or refresh the inbox when no conversation for
  /// its thread is on screen.
  Future<void> _mergePersistedMessage(
    MessageModel message,
    Emitter<MessageState> emit,
  ) async {
    try {
      final current = state;
      if (current is MessagesLoaded) {
        if (current.threadId == message.threadId) {
          var merged = message;
          // The user is LOOKING at this conversation: an incoming message is
          // read the moment it lands. Persist that too — without it the DB row
          // keeps is_read=0 and leaving the chat shows a ghost unread badge.
          if (message.type == MessageType.received && !message.isRead) {
            await _repository.markThreadAsRead(message.threadId);
            merged = MessageModel(
              id: message.id,
              threadId: message.threadId,
              contactId: message.contactId,
              phoneNumber: message.phoneNumber,
              body: message.body,
              type: message.type,
              status: message.status,
              timestamp: message.timestamp,
              isRead: true,
              deviceSmsId: message.deviceSmsId,
            );
          }
          // Dedupe: avoid appending if this message is already in the list (e.g. duplicate event).
          final alreadyPresent = current.messages.any(
            (m) =>
                m.id == merged.id ||
                (m.body == merged.body &&
                    m.timestamp == merged.timestamp &&
                    m.phoneNumber == merged.phoneNumber),
          );
          if (!alreadyPresent) {
            emit(
              MessagesLoaded(
                [...current.messages, merged],
                hasMore: current.hasMore,
                threadId: current.threadId,
              ),
            );
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

  /// Rebuilds the phone→name cache from freshly-fetched device contacts and
  /// re-resolves names on the currently-loaded threads, so a contact added on
  /// the device shows its name without a full (SMS re-import) refresh.
  Future<void> _onRefreshContactNames(
    RefreshContactNames event,
    Emitter<MessageState> emit,
  ) async {
    _cachedPhoneToName = null;
    try {
      // Pull fresh device contacts so the rebuilt map reflects the change.
      await _contactRepository.getAllContacts(forceRefresh: true);
    } catch (_) {
      // Fall through: _resolveContactNames will use whatever is available.
    }
    final current = state;
    if (current is ThreadsLoaded && !current.archived) {
      final enriched = await _resolveContactNames(current.threads);
      emit(ThreadsLoaded(enriched, hasMore: current.hasMore));
    }
  }

  Future<void> _onDeleteMessage(
    DeleteMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      // Global: provider row first (default-SMS-app), then local.
      await _smsService.deleteMessagesGlobally([event.messageId]);
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
      await _smsService.deleteThreadGlobally(event.threadId);
      add(const LoadThreads());
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onDeleteThreads(
    DeleteThreads event,
    Emitter<MessageState> emit,
  ) async {
    try {
      for (final id in event.threadIds) {
        await _smsService.deleteThreadGlobally(id);
      }
      final archived =
          state is ThreadsLoaded && (state as ThreadsLoaded).archived;
      add(LoadThreads(archived: archived));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onDeleteMessages(
    DeleteMessages event,
    Emitter<MessageState> emit,
  ) async {
    try {
      await _smsService.deleteMessagesGlobally(event.messageIds);
      // Reload the open conversation so the deleted bubbles disappear.
      add(LoadMessages(event.threadId));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onArchiveThreads(
    ArchiveThreads event,
    Emitter<MessageState> emit,
  ) async {
    try {
      for (final id in event.threadIds) {
        if (event.archive) {
          await _repository.archiveThread(id);
        } else {
          await _repository.unarchiveThread(id);
        }
      }
      add(LoadThreads(archived: event.fromArchivedView));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onPinThread(PinThread event, Emitter<MessageState> emit) async {
    try {
      if (event.pin) {
        await _repository.pinThread(event.threadId);
      } else {
        await _repository.unpinThread(event.threadId);
      }
      final archived =
          state is ThreadsLoaded && (state as ThreadsLoaded).archived;
      add(LoadThreads(archived: archived));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }

  Future<void> _onSetThreadRead(
    SetThreadRead event,
    Emitter<MessageState> emit,
  ) async {
    try {
      for (final id in event.threadIds) {
        if (event.read) {
          await _repository.markThreadAsRead(id);
        } else {
          await _repository.markThreadAsUnread(id);
        }
      }
      final archived =
          state is ThreadsLoaded && (state as ThreadsLoaded).archived;
      add(LoadThreads(archived: archived));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }
}
