import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'message_event.dart';
import 'message_state.dart';
import '../repositories/group_repository.dart';
import '../repositories/message_repository.dart';
import '../services/sms_service.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_name_cache.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import '../models/message_group.dart';
import '../models/message_model.dart';

class MessageBloc extends Bloc<MessageEvent, MessageState> {
  final MessageRepository _repository;
  final SmsService _smsService;
  final ContactRepository _contactRepository;
  final GroupRepository _groupRepository;
  static bool _hasImported = false;

  /// One-per-session cache of the normalized-number → contact name lookup table.
  ///
  /// Building this map requires fetching all device contacts (which is slow on
  /// the first call but fast once the ContactRepository cache is warm).
  /// Caching it here avoids re-fetching on every LoadThreads dispatch
  /// (e.g., on app resume, on tab switch, after sending a message).
  Map<String, String>? _cachedPhoneToName;

  /// Trailing-digits fallback built alongside [_cachedPhoneToName]: last-7-digits
  /// -> the one name owning that tail, null where two contacts share it. Dropped
  /// with it, so the two can never disagree.
  Map<String, String?>? _cachedTailToName;

  /// A device mirror-sync started by this bloc is still running. It runs OFF
  /// the event queue (see [_startBackgroundSync]), so this flag — not the queue
  /// — is what keeps two syncs from overlapping.
  bool _syncing = false;

  /// A pagination query is in flight. Without this a fast fling dispatched one
  /// [LoadMoreThreads] per scroll notification (the guard on `hasMore` only
  /// flips once the *previous* query returned), and the bloc then ran a dozen
  /// paged inbox queries back to back — the multi-second stall while scrolling.
  bool _loadingMoreThreads = false;
  bool _loadingMoreMessages = false;

  /// How many rows each inbox (active / archived) currently has paged in.
  ///
  /// A plain `LoadThreads()` (returning from a conversation, resume, after a
  /// send) carries the default limit of 50. Without this, a user who had
  /// scrolled 200 threads deep got the list cut back to 50 rows underneath
  /// them, and the scroll position collapsed to the top. Refreshes re-read as
  /// many rows as were on screen instead. The two inboxes are counted apart —
  /// they are separate screens and visiting one must not shrink the other.
  int _loadedThreadCount = 0;
  int _loadedArchivedCount = 0;

  int _pagedCount({required bool archived}) =>
      archived ? _loadedArchivedCount : _loadedThreadCount;

  void _setPagedCount(int count, {required bool archived}) {
    if (archived) {
      _loadedArchivedCount = count;
    } else {
      _loadedThreadCount = count;
    }
  }

  /// Dependencies default to real implementations so production callers can use
  /// `MessageBloc()`; tests can inject fakes/mocks.
  MessageBloc({
    MessageRepository? repository,
    SmsService? smsService,
    ContactRepository? contactRepository,
    GroupRepository? groupRepository,
  }) : _repository = repository ?? MessageRepository(),
       _smsService = smsService ?? SmsService(),
       _contactRepository = contactRepository ?? ContactRepository(),
       _groupRepository = groupRepository ?? GroupRepository(),
       super(const MessageInitial()) {
    on<LoadThreads>(_onLoadThreads);
    on<SyncDeviceMessages>(_onSyncDeviceMessages);
    on<DeviceSyncFinished>(_onDeviceSyncFinished);
    on<ThreadChangedExternally>(_onThreadChangedExternally);
    on<LoadMoreThreads>(_onLoadMoreThreads);
    on<LoadMessages>(_onLoadMessages);
    on<LoadMoreMessages>(_onLoadMoreMessages);
    on<SendMessage>(_onSendMessage);
    on<SendGroupMessage>(_onSendGroupMessage);
    on<RetryMessage>(_onRetryMessage);
    on<ReceiveMessage>(_onReceiveMessage);
    on<MessageSentExternally>(_onMessageSentExternally);
    on<MessageStatusChanged>(_onMessageStatusChanged);
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

    // Delivery reports: advance the tick on the open conversation's bubble.
    _statusSubscription = SmsService.onMessageStatusChanged.listen(
      (change) => add(
        MessageStatusChanged(
          change.messageId,
          change.status,
          replacement: change.replacement,
        ),
      ),
    );

    // NOTE: SMS listening will be initialized only after permissions are granted
    // and when LoadThreads event is first triggered (in _onLoadThreads)
  }

  /// The last state that is something to *look at* — a loaded inbox or a
  /// loaded conversation.
  ///
  /// `MessageSent`, `MessageSendFailed` and `MessageError` are one-shot
  /// **notifications** that happen to travel through the same state channel:
  /// they say what just happened, not what is on screen. Anything deciding
  /// whether there is a list to keep must ask this, not `state`.
  MessageState? _lastDurable;

  /// The last **inbox** this bloc emitted, kept apart from [_lastDurable].
  ///
  /// One bloc holds one state, so opening a conversation parks it on
  /// `MessagesLoaded` and the inbox is gone from `state` — which is why the
  /// forward picker, opened *from* a conversation, listed no «گفتگوهای اخیر»
  /// at all: it asked `state`, found a conversation, and answered with an empty
  /// list. This is the rows the inbox last had, so any screen that wants "who
  /// has this user been talking to" can ask without a query of its own.
  ThreadsLoaded? _lastInbox;

  /// See [_lastInbox]. Null before the inbox has ever been loaded.
  ThreadsLoaded? get lastInbox => _lastInbox;

  @override
  void onChange(Change<MessageState> change) {
    super.onChange(change);
    final next = change.nextState;
    if (next is ThreadsLoaded || next is MessagesLoaded) _lastDurable = next;
    if (next is ThreadsLoaded && !next.archived) _lastInbox = next;
  }

  /// Emits [notification] and then puts the bloc straight back on the state the
  /// screens actually paint.
  ///
  /// Leaving it parked on a notification is what broke sending in airplane
  /// mode: the inbox answers `MessageSendFailed` with a `LoadThreads`, which —
  /// finding a state that is neither loaded inbox nor loaded conversation —
  /// emitted `MessageLoading` over the open chat and then a `ThreadsLoaded` the
  /// chat's `buildWhen` ignores, so the spinner never went away.
  void _notify(Emitter<MessageState> emit, MessageState notification) {
    emit(notification);
    final durable = _lastDurable;
    if (durable != null) emit(durable);
  }

  StreamSubscription<MessageModel>? _sentSubscription;
  StreamSubscription<
    ({String messageId, MessageStatus status, MessageModel? replacement})
  >?
  _statusSubscription;

  @override
  Future<void> close() {
    _sentSubscription?.cancel();
    _statusSubscription?.cancel();
    return super.close();
  }

  /// Replaces the status of one message in the open conversation, in place.
  /// DB is already current (SmsService updated it before broadcasting).
  Future<void> _onMessageStatusChanged(
    MessageStatusChanged event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is! MessagesLoaded) return;
    final index = current.messages.indexWhere((m) => m.id == event.messageId);
    if (index == -1) return;
    // The send result rewrites more than the status (provider row id, the SIM
    // the radio really used, the moment it was accepted), so it hands the whole
    // row over. A carrier delivery report carries none of that and takes the
    // copyWith path — which is copyWith, NOT a hand-built model: rebuilding it
    // field by field drops whatever was added last (this is exactly how a
    // bubble lost its SIM badge the instant its delivery report landed).
    final updated =
        event.replacement ??
        current.messages[index].copyWith(status: event.status);
    final messages = [...current.messages];
    messages[index] = updated;
    emit(
      MessagesLoaded(
        messages,
        hasMore: current.hasMore,
        threadId: current.threadId,
      ),
    );
  }

  Future<void> _onLoadThreads(
    LoadThreads event,
    Emitter<MessageState> emit,
  ) async {
    // Only emit loading when there is genuinely nothing on screen to keep.
    // This prevents the chat screen from going black when an incoming SMS
    // triggers a background thread refresh (e.g. user on conversation for
    // another thread).
    //
    // `_lastDurable` rather than `state`, and that is load-bearing: `MessageSent`
    // and `MessageSendFailed` are one-shot *notifications*, not screen states,
    // and the inbox reacts to both by dispatching a `LoadThreads`. With the
    // plain check, a send that the radio refused left the open conversation on a
    // spinner FOR EVER — `MessageSendFailed` is neither of the two listed types,
    // so loading was emitted, and the `ThreadsLoaded` that followed is a state
    // the conversation's `buildWhen` ignores. That is the whole of "the message
    // vanished and the chat went blank" in airplane mode.
    if (_lastDurable == null) {
      emit(const MessageLoading());
    }

    // The device mirror-sync used to be awaited BEFORE the first inbox paint,
    // so a cold start sat on a spinner for as long as the provider read took
    // (seconds on a full phone). The local store is already a complete mirror
    // of the provider, so paint from it immediately and let the sync fold its
    // result in when it lands — see [_startBackgroundSync].
    final needsSync = !_hasImported || event.forceRefresh;
    if (needsSync) {
      // Started BEFORE the sync, not after it: an SMS arriving during that
      // first (multi-second) sync used to have no listener to land in.
      // `_hasImported` is only set once the sync actually succeeds (see
      // [_onDeviceSyncFinished]) so a permission-denied first run retries.
      _startSmsListener();
    }

    // Refreshing the first page: re-read whatever was already paged in, so the
    // list keeps its length (and the user keeps their scroll position).
    final paged = _pagedCount(archived: event.archived);
    final limit = event.offset == 0 && paged > event.limit
        ? paged
        : event.limit;

    try {
      await _emitThreads(
        emit,
        limit: limit,
        offset: event.offset,
        archived: event.archived,
      );
    } catch (e) {
      final errorMessage = e.toString().contains('Permission')
          ? 'دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.'
          : 'خطا در بارگذاری پیام‌ها: ${e.toString()}';
      emit(MessageError(errorMessage));
      return;
    }

    if (needsSync) _startBackgroundSync(forceRefresh: event.forceRefresh);
  }

  /// Reads one page of the inbox and emits it.
  ///
  /// Contact names come from the device address book; building that lookup map
  /// the first time means reading the whole book (and queueing behind whatever
  /// else `DeviceSyncQueue` is running). So when the map is cold the rows are
  /// painted first and the names land a moment later, instead of the whole
  /// inbox waiting on the address book.
  Future<void> _emitThreads(
    Emitter<MessageState> emit, {
    required int limit,
    required int offset,
    required bool archived,
  }) async {
    final rawThreads = await _repository.getAllThreads(
      limit: limit,
      offset: offset,
      archived: archived,
    );
    final hasMore = rawThreads.length >= limit;
    if (offset == 0) _setPagedCount(rawThreads.length, archived: archived);
    // `_syncing` is set before the first paint of a cold start, so an empty
    // inbox can say it is still importing instead of saying there is nothing.
    final syncing = _syncing || !_hasImported;
    if (_cachedPhoneToName == null && rawThreads.isNotEmpty) {
      // Not bare rows: the names this device resolved on its last run are in
      // SQLite, so the first paint of a launch already carries them. On a phone
      // whose address book has not changed since, the authoritative pass below
      // produces an identical `ThreadsLoaded` and nothing repaints at all.
      emit(
        ThreadsLoaded(
          await _resolveGroups(
            _applyNames(
              rawThreads,
              await _rememberedNames(),
              await _rememberedTailNames(),
            ),
          ),
          hasMore: hasMore,
          archived: archived,
          syncing: syncing,
        ),
      );
    }
    final threads = await _resolveGroups(
      await _resolveContactNames(rawThreads),
    );
    emit(
      ThreadsLoaded(
        threads,
        hasMore: hasMore,
        archived: archived,
        syncing: syncing,
      ),
    );
  }

  /// Attaches the [MessageGroup] to every group thread in [threads].
  ///
  /// The inbox query is deliberately blind to what kind of thread id it is
  /// paging (see [GroupThread]) — that is what lets pinning, archiving, the
  /// unread count and the search work on a group without a single branch — so the
  /// group itself is joined on afterwards, here.
  ///
  /// Read on demand instead of cached: it is two reads of tables holding a
  /// handful of rows, and a cache would have to be invalidated by the group
  /// details screen, a rename, a member added, a member removed and a delete —
  /// five paths that each look correct while showing a stale title.
  Future<List<MessageThread>> _resolveGroups(
    List<MessageThread> threads,
  ) async {
    if (!threads.any((t) => t.isGroup)) return threads;
    try {
      final groups = await _groupRepository.getAllByThreadId();
      return [
        for (final thread in threads)
          thread.isGroup
              ? thread.copyWith(group: groups[thread.threadId])
              : thread,
      ];
    } catch (_) {
      return threads;
    }
  }

  /// Starts the incoming-SMS listener once. The `SmsService._listening` guard
  /// makes repeat calls no-ops, but we skip them anyway so the EventChannel is
  /// never torn down and rebuilt (which would drop messages arriving in the
  /// gap).
  void _startSmsListener() {
    if (_smsService.isListening) return;
    try {
      _smsService.listenToIncomingSms();
    } catch (_) {
      // Not critical for basic functionality.
    }
  }

  /// Runs the device mirror-sync **off the bloc's event queue**.
  ///
  /// A bloc processes events one at a time, so awaiting the sync inside a
  /// handler stalled everything queued behind it — tapping a conversation
  /// during the first sync waited for the whole provider reconcile. Here the
  /// future runs on its own and only its (cheap) completion comes back as an
  /// event.
  void _startBackgroundSync({
    bool forceRefresh = false,
    bool throttle = false,
  }) {
    if (_syncing) return;
    _syncing = true;
    _smsService
        .syncDeviceMessages(
          forceRefresh: forceRefresh,
          throttle: throttle,
          onProgress: _onSyncProgress,
        )
        .then(
          (_) {
            if (!isClosed) add(const DeviceSyncFinished(ok: true));
          },
          onError: (_) {
            if (!isClosed) add(const DeviceSyncFinished(ok: false));
          },
        )
        .whenComplete(() {
          _syncing = false;
          // The mirror-sync is what inserts most messages, so this is where the
          // search index falls behind — and *after* it is where catching up is
          // free. Detached and off the event queue for the same reason the sync
          // itself is (see this method's doc).
          _drainSearchIndex();
        });
  }

  /// Last moment a mid-sync refresh was published.
  DateTime? _lastSyncProgressAt;

  /// A page of the first import landed.
  ///
  /// The first run on an existing phone walks the whole mailbox, which takes
  /// long enough that showing nothing until it finishes reads as a hang. This
  /// republishes what has arrived so far — throttled, because a refresh is a
  /// full inbox query and the import is deliberately made of many small pages.
  /// [LoadThreads] does not emit a loading state when threads are already on
  /// screen, so the list simply grows.
  void _onSyncProgress() {
    if (isClosed) return;
    final last = _lastSyncProgressAt;
    final now = DateTime.now();
    if (last != null && now.difference(last) < const Duration(seconds: 2)) {
      return;
    }
    _lastSyncProgressAt = now;
    if (state is ThreadsLoaded) add(const LoadThreads());
  }

  /// Whether a search-index backfill is already walking.
  bool _indexing = false;

  /// Folds pending message bodies into the FTS search index, a bounded batch at
  /// a time, until there is nothing left.
  ///
  /// Chunked rather than one pass on purpose: the first run on an existing
  /// mailbox has every row to do, and each batch yields to the event loop
  /// between commits so scrolling and typing keep their frames. Until it drains,
  /// searches simply use the scan path — `MessageRepository.searchIndexReady`
  /// refuses a half-filled index — so this is never load-bearing for
  /// correctness, only for speed.
  Future<void> _drainSearchIndex() async {
    if (_indexing) return;
    _indexing = true;
    try {
      while (!isClosed) {
        final done = await _repository.syncSearchIndex();
        if (done == 0) break;
        await Future<void>.delayed(Duration.zero);
      }
    } catch (_) {
      // A device without FTS5, or a transient write failure: the scan path is
      // still correct, so there is nothing to report.
    } finally {
      _indexing = false;
    }
  }

  /// Folds a finished background sync into whatever is on screen.
  Future<void> _onDeviceSyncFinished(
    DeviceSyncFinished event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (!event.ok) {
      // Permission denied / transient read failure. Only surface it when there
      // is nothing local to show — otherwise keep the mirror on screen.
      if (current is ThreadsLoaded && current.threads.isEmpty) {
        emit(
          const MessageError(
            'دسترسی به پیام‌ها رد شد. لطفاً مجوزهای لازم را بررسی کنید.',
          ),
        );
      }
      return;
    }
    _hasImported = true;
    await _refreshInPlace(emit);
  }

  /// A notification action wrote [ThreadChangedExternally.threadId]'s rows
  /// natively. An open conversation is refreshed only when it is that thread —
  /// any other one is unaffected, and the inbox is reloaded on the way back to
  /// it anyway.
  Future<void> _onThreadChangedExternally(
    ThreadChangedExternally event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is MessagesLoaded && current.threadId != event.threadId) return;
    await _refreshInPlace(emit);
  }

  /// Re-reads what is on screen — the open conversation's bubbles, or the
  /// inbox page(s) already loaded — and emits it with no loading state.
  Future<void> _refreshInPlace(Emitter<MessageState> emit) async {
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
        await _emitThreads(
          emit,
          limit: current.threads.length > 50 ? current.threads.length : 50,
          offset: 0,
          archived: current.archived,
        );
      }
    } catch (_) {
      // Silent by design.
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
    // Resume-triggered: throttled so rapid app switches don't re-run the
    // expensive full device reconcile every time. Runs off the event queue;
    // the refresh happens in [_onDeviceSyncFinished].
    _startBackgroundSync(throttle: true);
  }

  Future<void> _onLoadMoreThreads(
    LoadMoreThreads event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is! ThreadsLoaded || !current.hasMore) return;
    if (_loadingMoreThreads) return;
    _loadingMoreThreads = true;
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
      final resolved = await _resolveGroups(await _resolveContactNames(more));
      final combined = [...current.threads, ...resolved];
      _setPagedCount(combined.length, archived: current.archived);
      emit(
        ThreadsLoaded(
          combined,
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
    } finally {
      _loadingMoreThreads = false;
    }
  }

  Future<void> _onLoadMoreMessages(
    LoadMoreMessages event,
    Emitter<MessageState> emit,
  ) async {
    final current = state;
    if (current is! MessagesLoaded || !current.hasMore) return;
    if (_loadingMoreMessages) return;
    _loadingMoreMessages = true;
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
    } finally {
      _loadingMoreMessages = false;
    }
  }

  Future<void> _onSendMessage(
    SendMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      final result = await _smsService.sendSms(
        event.phoneNumber,
        event.body,
        subscriptionId: event.subscriptionId,
      );
      if (result.success) {
        _notify(emit, const MessageSent());
        // Let the UI screens decide what to reload based on their context.
      } else {
        _notify(
          emit,
          MessageSendFailed(
            errorCode: result.errorCode ?? 'SMS_SEND_FAILED',
            userMessage: _localizedSendError(result.errorCode),
          ),
        );
      }
    } catch (e) {
      _notify(
        emit,
        MessageSendFailed(
          errorCode: 'SMS_SEND_FAILED',
          userMessage: _localizedSendError(null),
        ),
      );
    }
  }

  /// «پیام گروهی»: one send per member, one bubble.
  ///
  /// Membership is read here rather than carried in the event, because the group
  /// may have changed since the composer was opened — the message goes to whoever
  /// is in it now.
  Future<void> _onSendGroupMessage(
    SendGroupMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      final group = await _groupRepository.getById(event.groupId);
      if (group == null || group.members.isEmpty) {
        _notify(
          emit,
          const MessageSendFailed(
            errorCode: 'SMS_SEND_FAILED',
            userMessage: 'این گروه عضوی ندارد.',
          ),
        );
        return;
      }
      final result = await _smsService.sendGroupSms(
        group: group,
        body: event.body,
        subscriptionId: event.subscriptionId,
      );
      // The group's «آخرین فعالیت» follows its conversation, so the details list
      // and the recipient picker order the newest group first.
      await _groupRepository.touch(event.groupId);
      if (result.success) {
        _notify(emit, const MessageSent());
      } else {
        _notify(
          emit,
          MessageSendFailed(
            errorCode: result.errorCode ?? 'SMS_SEND_FAILED',
            userMessage: _localizedSendError(result.errorCode),
          ),
        );
      }
    } catch (_) {
      _notify(
        emit,
        MessageSendFailed(
          errorCode: 'SMS_SEND_FAILED',
          userMessage: _localizedSendError(null),
        ),
      );
    }
  }

  /// «ارسال مجدد» on a failed bubble.
  ///
  /// The row is already in the DB — `SmsService` broadcasts pending → sent on
  /// the status stream and the bubble follows it in place — but the same
  /// notifications a first send produces are emitted anyway, because the
  /// in-place swap only lands while the bloc happens to be sitting on this
  /// conversation's state, and the screens reload themselves off those.
  Future<void> _onRetryMessage(
    RetryMessage event,
    Emitter<MessageState> emit,
  ) async {
    try {
      final result = await _smsService.resendMessage(event.messageId);
      if (result.success) {
        // Same notification a first-time send produces, and for the same
        // reason: the screens reload themselves off it. Without it a retry that
        // worked left the bubble red until the thread was re-opened, because
        // the in-place status swap only lands while the bloc happens to be
        // sitting on this conversation's state.
        _notify(emit, const MessageSent());
      } else {
        _notify(
          emit,
          MessageSendFailed(
            errorCode: result.errorCode ?? 'SMS_SEND_FAILED',
            userMessage: _localizedSendError(result.errorCode),
          ),
        );
      }
    } catch (_) {
      _notify(
        emit,
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
        final tails = <String, String?>{};
        for (final c in contacts) {
          if (c.name.isEmpty) continue;
          for (final phone in [...c.phoneNumbers, c.phoneNumber]) {
            // Key on the normalized national number (09xxxxxxxxx) so a contact
            // saved as 0912… still matches an incoming SMS whose address is the
            // E.164 form (+98912…). Keying on raw digits missed those.
            final key = PhoneNormalizer.toThreadId(phone);
            if (key.isNotEmpty) map[key] = c.name;
            // …and the trailing-digits fallback, for the shapes the normalizer
            // has no rule for. See [PhoneNormalizer.toTailKey].
            final tail = PhoneNormalizer.toTailKey(phone);
            if (tail.isEmpty) continue;
            tails.update(
              tail,
              (existing) => existing == c.name ? existing : null,
              ifAbsent: () => c.name,
            );
          }
        }
        _cachedPhoneToName = map;
        _cachedTailToName = tails;
      }

      return _applyNames(threads, _cachedPhoneToName!, _cachedTailToName);
    } catch (_) {
      return threads;
    }
  }

  /// Titles [threads] from [phoneToName] — and **untitles** the ones it has no
  /// name for.
  ///
  /// The overwrite is the point. This used to keep any name a row already
  /// carried, which reads as an optimization and is a bug: `RefreshContactNames`
  /// re-resolves the rows that are *already on screen*, so a contact the user
  /// had just deleted went on naming its conversation until something happened
  /// to re-read the inbox from SQLite. A name has to be able to disappear.
  ///
  /// Group rows are left exactly as they are: their title comes from the group,
  /// not from the address book (see [_resolveGroups]).
  /// [tailToName] is the trailing-digits fallback, consulted only when the
  /// exact key misses and only where the tail names exactly one person (a
  /// shared tail is stored as null). Without it the inbox disagreed with the
  /// ringing screen, which resolves through `PhoneLookup` — see
  /// [PhoneNormalizer.toTailKey].
  static List<MessageThread> _applyNames(
    List<MessageThread> threads,
    Map<String, String> phoneToName, [
    Map<String, String?>? tailToName,
  ]) {
    return [
      for (final thread in threads)
        if (thread.isGroup)
          thread
        else
          () {
            final key = PhoneNormalizer.toThreadId(thread.phoneNumber);
            var name = key.isEmpty ? null : phoneToName[key];
            if (name == null && tailToName != null) {
              final tail = PhoneNormalizer.toTailKey(thread.phoneNumber);
              if (tail.isNotEmpty) name = tailToName[tail];
            }
            final resolved = (name == null || name.isEmpty) ? null : name;
            if (resolved == thread.contactName) return thread;
            return thread.copyWith(
              contactName: resolved,
              clearContactName: resolved == null,
            );
          }(),
    ];
  }

  /// The names the **last** run resolved, read from SQLite.
  ///
  /// Used for the very first emit of a launch: the real address-book read is a
  /// platform-channel round trip over the whole book, and waiting for it is why
  /// the inbox painted bare numbers and dropped the names in a beat later on
  /// every single launch. This answers from the database that is already open,
  /// and the authoritative read then corrects it — silently when nothing has
  /// changed, because [ThreadsLoaded] is Equatable and an identical emit never
  /// reaches the screen.
  Future<Map<String, String>> _rememberedNames() async {
    final cached = await ContactNameCache.read();
    return {for (final entry in cached.entries) entry.key: entry.value.name};
  }

  /// The trailing-digits half of [_rememberedNames], derived from the same
  /// table, so the *first* paint of a launch resolves exactly what the
  /// authoritative pass behind it will — otherwise a contact only the loose
  /// match finds appeared as a number and was replaced by a name a beat later,
  /// which is the flicker the cache exists to remove.
  Future<Map<String, String?>> _rememberedTailNames() async {
    final cached = await ContactNameCache.read();
    final tails = <String, String?>{};
    cached.forEach((normalized, entry) {
      final tail = PhoneNormalizer.toTailKey(normalized);
      if (tail.isEmpty) return;
      tails.update(
        tail,
        (existing) => existing == entry.name ? existing : null,
        ifAbsent: () => entry.name,
      );
    });
    return tails;
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
      var merged = message;
      // The user is LOOKING at this conversation: an incoming message is
      // read the moment it lands. Persist that too — without it the DB row
      // keeps is_read=0 and leaving the chat shows a ghost unread badge.
      //
      // Done BEFORE `state` is read, and that ordering is the fix for "several
      // messages arrive at once and only the last one shows up". A bloc's
      // default transformer processes events **concurrently**, so two arrivals
      // a few milliseconds apart both suspended on this `await` while holding
      // the same pre-merge `current`, and the second emit rebuilt the list from
      // it — dropping the first message on the floor. `state` is a getter, so
      // reading it after every suspension point is always the live value.
      if (state is MessagesLoaded &&
          (state as MessagesLoaded).threadId == message.threadId &&
          message.type == MessageType.received &&
          !message.isRead) {
        await _repository.markThreadAsRead(message.threadId);
        merged = message.copyWith(isRead: true);
      }
      final current = state;
      if (current is MessagesLoaded) {
        if (current.threadId == message.threadId) {
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
    // Only the local map is dropped: whoever dispatched this (the address-book
    // change listener, the resume poll) also asks ContactBloc to refresh, and
    // forcing a second read here meant marshalling the whole address book over
    // the platform channel twice per refresh.
    _cachedPhoneToName = null;
    _cachedTailToName = null;
    final current = state;
    if (current is ThreadsLoaded && !current.archived) {
      final enriched = await _resolveContactNames(current.threads);
      // A group member's name is denormalized into `message_group_members` so a
      // group can be titled without reading the address book. This is the one
      // place that copy is refreshed — otherwise renaming a contact left every
      // group they are in showing the old name for ever.
      final index = _cachedPhoneToName;
      if (index != null && index.isNotEmpty) {
        try {
          final changed = await _groupRepository.refreshMemberNames(index);
          if (changed > 0) {
            emit(
              ThreadsLoaded(
                await _resolveGroups(enriched),
                hasMore: current.hasMore,
              ),
            );
            return;
          }
        } catch (_) {
          // A stale denormalized name is not worth failing a refresh over.
        }
      }
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
      // The conversation is gone; its shade card must go with it or the
      // launcher badge keeps counting a thread that no longer exists.
      unawaited(DeepLinkService.instance.reconcileNotifications());
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
      unawaited(DeepLinkService.instance.reconcileNotifications());
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
      // A thread marked read from the inbox has to lose its shade card too, or
      // the launcher badge goes on counting messages the user has answered for.
      if (event.read) {
        unawaited(DeepLinkService.instance.reconcileNotifications());
      }
      final archived =
          state is ThreadsLoaded && (state as ThreadsLoaded).archived;
      add(LoadThreads(archived: archived));
    } catch (e) {
      emit(MessageError(e.toString()));
    }
  }
}
