import 'package:equatable/equatable.dart';

abstract class CallLogEvent extends Equatable {
  const CallLogEvent();

  @override
  List<Object?> get props => [];
}

class LoadCallLogs extends CallLogEvent {
  const LoadCallLogs();
}

class RefreshCallLogs extends CallLogEvent {
  const RefreshCallLogs();
}

class DeleteCallLog extends CallLogEvent {
  final String id;

  const DeleteCallLog(this.id);

  @override
  List<Object?> get props => [id];
}
























