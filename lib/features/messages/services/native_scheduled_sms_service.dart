import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart bridge to the native AlarmManager that delivers scheduled messages in
/// the background (PHASE 2). See `android/.../scheduled/` on the native side.
///
/// All calls are best-effort: on platforms without the channel (tests, other
/// OSes) the errors are swallowed so callers never need to guard.
class NativeScheduledSmsService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/scheduled_sms',
  );

  /// Ask the native side to (re)arm the alarm for the soonest pending schedule.
  /// Call after any change to the scheduled_messages table.
  Future<void> reschedule() async {
    try {
      await _channel.invokeMethod<void>('reschedule');
    } catch (e) {
      debugPrint('NativeScheduledSmsService.reschedule failed: $e');
    }
  }

  /// Cancel the pending alarm (no schedules left).
  Future<void> cancel() async {
    try {
      await _channel.invokeMethod<void>('cancel');
    } catch (e) {
      debugPrint('NativeScheduledSmsService.cancel failed: $e');
    }
  }
}
