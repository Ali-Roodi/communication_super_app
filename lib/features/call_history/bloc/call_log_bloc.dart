import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'call_log_event.dart';
import 'call_log_state.dart';
import '../services/call_log_service.dart';
import '../services/native_call_log_service.dart';
import '../repositories/call_log_repository.dart';

const int _callLogPageSize = 50;

class CallLogBloc extends Bloc<CallLogEvent, CallLogState> {
  final CallLogService _service;
  final CallLogRepository _repository;
  final bool _observeDeviceChanges;
  bool _isLoadingMore = false;
  StreamSubscription<void>? _deviceChangeSub;

  /// Dependencies default to real implementations so production callers can use
  /// `CallLogBloc()`; tests can inject fakes/mocks.
  CallLogBloc({
    CallLogService? service,
    CallLogRepository? repository,
    bool observeDeviceChanges = true,
  }) : _service = service ?? CallLogService(),
       _repository = repository ?? CallLogRepository(),
       _observeDeviceChanges = observeDeviceChanges,
       super(const CallLogInitial()) {
    on<LoadCallLogs>(_onLoadCallLogs);
    on<RefreshCallLogs>(_onRefreshCallLogs);
    on<LoadMoreCallLogs>(_onLoadMoreCallLogs);
    on<SyncCallLogs>(_onSyncCallLogs);
    on<RefreshCallLogContactNames>(_onRefreshContactNames);
    on<DeleteCallLog>(_onDeleteCallLog);
    on<DeleteCallLogs>(_onDeleteCallLogs);
    on<ClearCallLogs>(_onClearCallLogs);

    // Live sync: the device call-log provider changed (a call just ended, a
    // row was deleted elsewhere) → silent mirror-sync. Disabled in unit tests.
    if (observeDeviceChanges) {
      _deviceChangeSub = NativeCallLogService.instance.onCallLogChanged.listen(
        (_) => add(const SyncCallLogs()),
      );
    }
  }

  @override
  Future<void> close() {
    _deviceChangeSub?.cancel();
    return super.close();
  }

  /// «اخیر» on a launch: **paint the local mirror, then improve it.**
  ///
  /// This used to `await` the device mirror-sync and the address-book read
  /// before it emitted anything, behind a full-screen spinner — a second or
  /// two of «در حال بارگذاری» on every single open, over rows that were
  /// already in SQLite and unchanged since the last launch. The same mistake
  /// `MessageBloc` fixed for the inbox, and fixed the same way:
  ///
  /// 1. the local page goes out immediately, named from the persisted
  ///    address-book cache (`ContactNameCache`) — SQLite, no channel;
  /// 2. the authoritative names are overlaid as a second emit (the address-book
  ///    read is the expensive half). On a phone whose contacts have not changed
  ///    that emit is equal to the first and repaints nothing;
  /// 3. the device sync runs **detached** and re-emits only if it changed
  ///    something.
  ///
  /// A spinner is emitted only when there is genuinely nothing to show yet —
  /// never over a list the user is already looking at.
  Future<void> _onLoadCallLogs(
    LoadCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    final current = state;
    if (current is! CallLogsLoaded) emit(const CallLogLoading());
    try {
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      final hasMore = page.length >= _callLogPageSize;
      if (page.isEmpty && !_deviceSyncDone) {
        // Nothing in the mirror *and* the device has not been read yet — a
        // first launch. «تماس اخیری وجود ندارد» here is a claim the app cannot
        // make: it would flash over a phone full of calls for as long as the
        // import takes. Stay on the loading state; [_backgroundSync]
        // re-dispatches the moment it lands.
        unawaited(_backgroundSync());
        return;
      }
      // First paint: the mirror's rows, named from what the last run resolved
      // (SQLite, no channel round trip). Bare numbers here is what made every
      // launch show the list twice — once as numbers, once with names.
      if (page.isNotEmpty) {
        emit(
          CallLogsLoaded(
            await CallLogService.applyRememberedNames(page),
            hasMore: hasMore,
          ),
        );
      }
      // Then the names. `getAllContacts` is a cached hand-back after the first
      // call, so this is only slow once per process.
      final named = await _service.resolveContactNames(page);
      emit(CallLogsLoaded(named, hasMore: hasMore));
    } catch (e) {
      if (state is! CallLogsLoaded) emit(CallLogError(e.toString()));
    }
    // Detached on purpose: awaiting it here is what made the tab wait for the
    // provider. It re-emits through `SyncCallLogs` when it finds anything.
    unawaited(_backgroundSync());
  }

  /// The device half of a load: attach the observer and mirror the provider,
  /// then re-read so anything it imported is painted. Never throws into the
  /// bloc.
  ///
  /// **Runs at most once per bloc**, which is what makes the re-dispatch safe:
  /// `ensureSynced` imports whenever the mirror is empty, so on a phone whose
  /// call log is genuinely empty (a fresh device, or READ_CALL_LOG refused) an
  /// unlatched version would load, sync, load, sync for ever. Every later
  /// change arrives through the native ContentObserver instead, and
  /// «کشیدن برای تازه‌سازی» forces its own pass.
  Future<void> _backgroundSync() async {
    if (_deviceSyncStarted) return;
    _deviceSyncStarted = true;
    try {
      // (Re)attach the native ContentObserver — the first attempt may have run
      // before the READ_CALL_LOG grant.
      if (_observeDeviceChanges) {
        await NativeCallLogService.instance.initialize();
      }
      await _service.ensureSynced();
    } catch (_) {
      // Keep whatever the mirror already holds; the list is already on screen.
    }
    _deviceSyncDone = true;
    if (!isClosed) add(const LoadCallLogs());
  }

  /// The one-per-process device pass: started, and finished. [_deviceSyncDone]
  /// is what tells «the mirror is empty» apart from «the mirror has not been
  /// filled yet» — the empty state and the loading state.
  bool _deviceSyncStarted = false;
  bool _deviceSyncDone = false;

  Future<void> _onRefreshCallLogs(
    RefreshCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    // A pull-to-refresh is its own device pass, so nothing is pending after it
    // either way.
    _deviceSyncStarted = true;
    _deviceSyncDone = true;
    // No spinner over a list that is already on screen: the pull-to-refresh
    // gesture draws its own, and swapping the rows for a centred spinner threw
    // the scroll position away on every pull.
    if (state is! CallLogsLoaded) emit(const CallLogLoading());
    try {
      await _service.ensureSynced(forceRefresh: true);
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      final callLogs = await _service.resolveContactNames(page);
      emit(CallLogsLoaded(callLogs, hasMore: page.length >= _callLogPageSize));
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }

  Future<void> _onLoadMoreCallLogs(
    LoadMoreCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    if (_isLoadingMore) return;
    final current = state;
    if (current is! CallLogsLoaded || !current.hasMore) return;
    _isLoadingMore = true;
    try {
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: current.callLogs.length,
      );
      if (page.isEmpty) {
        emit(CallLogsLoaded(current.callLogs, hasMore: false));
        return;
      }
      final more = await _service.resolveContactNames(page);
      emit(
        CallLogsLoaded([
          ...current.callLogs,
          ...more,
        ], hasMore: page.length >= _callLogPageSize),
      );
    } catch (_) {
      emit(CallLogsLoaded(current.callLogs, hasMore: false));
    } finally {
      _isLoadingMore = false;
    }
  }

  /// Silent mirror-sync (no loading state, no flicker). Keeps however many
  /// rows are currently on screen so pagination position survives the sync.
  Future<void> _onSyncCallLogs(
    SyncCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    final current = state;
    final limit = current is CallLogsLoaded
        ? (current.callLogs.length > _callLogPageSize
              ? current.callLogs.length
              : _callLogPageSize)
        : _callLogPageSize;
    try {
      await _service.syncFromDevice();
      final page = await _repository.getAllCallLogs(limit: limit, offset: 0);
      final callLogs = await _service.resolveContactNames(page);
      emit(CallLogsLoaded(callLogs, hasMore: page.length >= limit));
    } catch (_) {
      // Silent by design: keep whatever is on screen.
    }
  }

  /// Re-overlays contact names onto the rows already on screen.
  ///
  /// The rows are re-read from the mirror rather than patched in place, because
  /// a name has to be able to *disappear*: `resolveContactNames` only overlays
  /// a match, so patching would leave a deleted contact's name on the row for
  /// ever. The DB never stores one, so a re-read is the clean slate. No device
  /// access, no loading state, and the paged-in length is preserved.
  Future<void> _onRefreshContactNames(
    RefreshCallLogContactNames event,
    Emitter<CallLogState> emit,
  ) async {
    final current = state;
    if (current is! CallLogsLoaded || current.callLogs.isEmpty) return;
    final limit = current.callLogs.length;
    try {
      CallLogService.invalidateCache();
      final page = await _repository.getAllCallLogs(limit: limit, offset: 0);
      emit(
        CallLogsLoaded(
          await _service.resolveContactNames(page),
          hasMore: current.hasMore,
        ),
      );
    } catch (_) {
      // Silent by design: keep whatever is on screen.
    }
  }

  Future<void> _onDeleteCallLog(
    DeleteCallLog event,
    Emitter<CallLogState> emit,
  ) async {
    await _deleteThenReload(
      emit,
      () => _service.deleteCallLogsGlobally([event.id]),
    );
  }

  Future<void> _onDeleteCallLogs(
    DeleteCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    if (event.ids.isEmpty) return;
    await _deleteThenReload(
      emit,
      () => _service.deleteCallLogsGlobally(event.ids),
    );
  }

  /// Empties the history. Emits the empty list only when the *provider* delete
  /// went through — a refused one leaves the rows on screen with an error,
  /// rather than showing an empty list that fills itself back in.
  Future<void> _onClearCallLogs(
    ClearCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    try {
      if (await _service.clearAllCallLogsGlobally()) {
        emit(const CallLogsLoaded([], hasMore: false));
      } else {
        // Report it, then put the list back: a refused clear must not leave the
        // user on an error page with no way back to their calls.
        emit(const CallLogError('پاک کردن سابقه تماس ممکن نشد'));
        add(const LoadCallLogs());
      }
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }

  Future<void> _deleteThenReload(
    Emitter<CallLogState> emit,
    Future<void> Function() delete,
  ) async {
    try {
      await delete();
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      final callLogs = await _service.resolveContactNames(page);
      emit(CallLogsLoaded(callLogs, hasMore: page.length >= _callLogPageSize));
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }
}
