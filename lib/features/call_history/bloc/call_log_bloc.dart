import 'package:flutter_bloc/flutter_bloc.dart';
import 'call_log_event.dart';
import 'call_log_state.dart';
import '../services/call_log_service.dart';
import '../repositories/call_log_repository.dart';

const int _callLogPageSize = 50;

class CallLogBloc extends Bloc<CallLogEvent, CallLogState> {
  final CallLogService _service;
  final CallLogRepository _repository;
  bool _isLoadingMore = false;

  /// Dependencies default to real implementations so production callers can use
  /// `CallLogBloc()`; tests can inject fakes/mocks.
  CallLogBloc({CallLogService? service, CallLogRepository? repository})
    : _service = service ?? CallLogService(),
      _repository = repository ?? CallLogRepository(),
      super(const CallLogInitial()) {
    on<LoadCallLogs>(_onLoadCallLogs);
    on<RefreshCallLogs>(_onRefreshCallLogs);
    on<LoadMoreCallLogs>(_onLoadMoreCallLogs);
    on<DeleteCallLog>(_onDeleteCallLog);
    on<DeleteCallLogs>(_onDeleteCallLogs);
  }

  Future<void> _onLoadCallLogs(
    LoadCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    emit(const CallLogLoading());
    try {
      await _service.getCallLogs();
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
      await _service.getCallLogs(forceRefresh: true);
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

  Future<void> _onDeleteCallLog(
    DeleteCallLog event,
    Emitter<CallLogState> emit,
  ) async {
    await _deleteThenReload(emit, () => _repository.deleteCallLog(event.id));
  }

  Future<void> _onDeleteCallLogs(
    DeleteCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    if (event.ids.isEmpty) return;
    await _deleteThenReload(emit, () => _repository.deleteCallLogs(event.ids));
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
