import 'package:flutter_bloc/flutter_bloc.dart';
import 'call_log_event.dart';
import 'call_log_state.dart';
import '../services/call_log_service.dart';
import '../repositories/call_log_repository.dart';

class CallLogBloc extends Bloc<CallLogEvent, CallLogState> {
  final CallLogService _service = CallLogService();
  final CallLogRepository _repository = CallLogRepository();

  CallLogBloc() : super(const CallLogInitial()) {
    on<LoadCallLogs>(_onLoadCallLogs);
    on<RefreshCallLogs>(_onRefreshCallLogs);
    on<DeleteCallLog>(_onDeleteCallLog);
  }

  Future<void> _onLoadCallLogs(
    LoadCallLogs event,
    Emitter<CallLogState> emit,
  ) async {
    emit(const CallLogLoading());
    try {
      final callLogs = await _service.getCallLogs();
      emit(CallLogsLoaded(callLogs));
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
      final callLogs = await _service.getCallLogs(forceRefresh: true);
      emit(CallLogsLoaded(callLogs));
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }

  Future<void> _onDeleteCallLog(
    DeleteCallLog event,
    Emitter<CallLogState> emit,
  ) async {
    try {
      await _repository.deleteCallLog(event.id);
      final callLogs = await _repository.getAllCallLogs();
      emit(CallLogsLoaded(callLogs));
    } catch (e) {
      emit(CallLogError(e.toString()));
    }
  }
}







