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
  }

  Future<void> _onLoadCallLogs(
    LoadCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    emit(const CallLogLoading());
    try {
      await _service.getCallLogs();
      final callLogs = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      emit(
        CallLogsLoaded(callLogs, hasMore: callLogs.length >= _callLogPageSize),
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
      final callLogs = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      emit(
        CallLogsLoaded(callLogs, hasMore: callLogs.length >= _callLogPageSize),
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
      final more = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: current.callLogs.length,
      );
      if (more.isEmpty) {
        emit(CallLogsLoaded(current.callLogs, hasMore: false));
        return;
      }
      emit(
        CallLogsLoaded([
          ...current.callLogs,
          ...more,
        ], hasMore: more.length >= _callLogPageSize),
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
    try {
      await _repository.deleteCallLog(event.id);
      final callLogs = await _repository.getAllCallLogs(
        limit: _callLogPageSize,
        offset: 0,
      );
      emit(
        CallLogsLoaded(callLogs, hasMore: callLogs.length >= _callLogPageSize),
      );
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }
}
