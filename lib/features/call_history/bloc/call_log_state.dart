import 'package:equatable/equatable.dart';
import '../models/call_log_model.dart';

abstract class CallLogState extends Equatable {
  const CallLogState();

  @override
  List<Object?> get props => [];
}

class CallLogInitial extends CallLogState {
  const CallLogInitial();
}

class CallLogLoading extends CallLogState {
  const CallLogLoading();
}

class CallLogsLoaded extends CallLogState {
  final List<CallLogModel> callLogs;
  final bool hasMore;

  const CallLogsLoaded(this.callLogs, {this.hasMore = false});

  @override
  List<Object?> get props => [callLogs, hasMore];
}

class CallLogError extends CallLogState {
  final String message;

  const CallLogError(this.message);

  @override
  List<Object?> get props => [message];
}
