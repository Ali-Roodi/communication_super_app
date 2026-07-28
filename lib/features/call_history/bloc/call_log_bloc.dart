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
    on<DeleteCallLog>(_onDeleteCallLog);
    on<DeleteCallLogs>(_onDeleteCallLogs);

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

  Future<void> _onLoadCallLogs(
    LoadCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    emit(const CallLogLoading());
    try {
      // (Re)attach the native ContentObserver — the first attempt may have run
      // before the READ_CALL_LOG grant.
      if (_observeDeviceChanges) {
        await NativeCallLogService.instance.initialize();
      }
      await _service.ensureSynced();
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      // The DB doesn't store contact_name, so resolve it from the current
      // contacts before display.
      final callLogs = await _service.resolveContactNames(page);
      emit(
        CallLogsLoaded(callLogs, hasMore: page.length >= _callLogPageSize),
      );
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }

  Future<void> _onRefreshCallLogs(
    RefreshCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    emit(const CallLogLoading());
    try {
      await _service.ensureSynced(forceRefresh: true);
      final page = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      final callLogs = await _service.resolveContactNames(page);
      emit(
        CallLogsLoaded(callLogs, hasMore: page.length >= _callLogPageSize),
      );
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
      emit(
        CallLogsLoaded(callLogs, hasMore: page.length >= _callLogPageSize),
      );
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }
}
