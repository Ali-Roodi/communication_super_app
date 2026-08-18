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

/// Silent device mirror-sync: refreshes the list **without** emitting a
/// loading state, so the screen never flashes. Fired by the native
/// ContentObserver (a call just ended / a row changed) and on app resume.
class SyncCallLogs extends CallLogEvent {
  const SyncCallLogs();
}

/// Re-resolve the contact name on every row already on screen, without touching
/// the device.
///
/// `call_logs` does not store a contact name — it is overlaid from the address
/// book as the page is read — so a rename leaves every recents row showing the
/// old one until something re-reads. Nothing did, which is why «اخیر» only
/// caught up on the next app start. Silent and device-free: this fires on an
/// address-book change, not a call-log one.
class RefreshCallLogContactNames extends CallLogEvent {
  const RefreshCallLogContactNames();
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

/// «پاک کردن سابقه تماس» — the whole history, device provider included.
///
/// Distinct from `DeleteCallLogs(everything loaded)`, which is what this used
/// to be: the list is paged, so that only cleared what had been scrolled into
/// memory.
class ClearCallLogs extends CallLogEvent {
  const ClearCallLogs();
}
