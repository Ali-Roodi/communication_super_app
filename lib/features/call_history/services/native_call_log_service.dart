import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart side of the native call-log sync bridge.
///
/// - [onCallLogChanged] fires (debounced natively) whenever the device call-log
///   provider changes — a call ended, a row was deleted from another app, etc.
///   `CallLogBloc` listens and runs a silent mirror-sync so «اخیر» stays live.
/// - [deleteDeviceCallLogs] removes rows from the *device* provider so an
///   in-app delete is global and never resurrects on the next import.
///
/// Static/singleton by design: the EventChannel must have exactly one active
/// subscription (mirrors the `NativeSmsService` pattern).
class NativeCallLogService {
  NativeCallLogService._();
  static final NativeCallLogService instance = NativeCallLogService._();

  static const MethodChannel _methodChannel = MethodChannel(
    'com.example.communication_super_app/call_log',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.example.communication_super_app/call_log_events',
  );

  final StreamController<void> _changeController =
      StreamController<void>.broadcast();
  StreamSubscription<dynamic>? _subscription;
  bool _initialized = false;

  /// Fires when the device call log changes. Listen and re-sync.
  Stream<void> get onCallLogChanged => _changeController.stream;

  /// Starts listening to native change events. Safe to call repeatedly —
  /// subsequent calls only re-ask the native side to (re)attach its
  /// ContentObserver, which matters when the first attempt ran before the
  /// READ_CALL_LOG grant.
  Future<void> initialize() async {
    if (!_initialized) {
      _subscription = _eventChannel.receiveBroadcastStream().listen(
        (_) => _changeController.add(null),
        onError: (Object e) =>
            debugPrint('Call-log EventChannel error: $e'),
        cancelOnError: false,
      );
      _initialized = true;
    }
    try {
      await _methodChannel.invokeMethod('ensureObserving');
    } catch (e) {
      debugPrint('ensureObserving failed: $e');
    }
  }

  /// Provider row ids of every device call at or after [sinceMs].
  ///
  /// Ids only: the mirror-sync needs this just to spot rows deleted elsewhere,
  /// and reading full rows for that is what made the sync O(history) in binder
  /// traffic. Returns null when the native side can't answer (no permission,
  /// older build without the method) — the caller then skips the deletion half
  /// rather than wrongly purging.
  Future<Set<String>?> deviceCallLogIdsSince(int sinceMs) async {
    try {
      final ids = await _methodChannel.invokeListMethod<String>(
        'callLogIdsSince',
        {'sinceMs': sinceMs},
      );
      return ids?.toSet();
    } on PlatformException catch (e) {
      debugPrint('Device call-log id query failed: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Deletes the given provider row ids from the device call log.
  /// Returns the number of rows the provider reported deleted.
  Future<int> deleteDeviceCallLogs(List<String> ids) async {
    if (ids.isEmpty) return 0;
    try {
      final deleted = await _methodChannel.invokeMethod<int>(
        'deleteCallLogs',
        {'ids': ids},
      );
      return deleted ?? 0;
    } on PlatformException catch (e) {
      debugPrint('Device call-log delete failed: ${e.code} ${e.message}');
      return 0;
    }
  }

  @visibleForTesting
  void dispose() {
    _subscription?.cancel();
    _subscription = null;
    _initialized = false;
  }
}
