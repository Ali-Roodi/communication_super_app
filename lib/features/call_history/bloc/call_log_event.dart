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

class LoadMoreCallLogs extends CallLogEvent {
  const LoadMoreCallLogs();
}

class DeleteCallLog extends CallLogEvent {
  final String id;

  const DeleteCallLog(this.id);

  @override
  List<Object?> get props => [id];
}

/// Deletes every call in a collapsed recents row in one shot, so a group shown
/// as "(۴)" disappears entirely instead of shrinking to "(۳)".
class DeleteCallLogs extends CallLogEvent {
  final List<String> ids;

  const DeleteCallLogs(this.ids);

  @override
  List<Object?> get props => [ids];
}
