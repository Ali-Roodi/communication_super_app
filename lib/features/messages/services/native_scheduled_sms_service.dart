import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Dart bridge to the native AlarmManager that delivers scheduled messages in
/// the background (PHASE 2). See `android/.../scheduled/` on the native side.
///
/// The channel is bidirectional: Dart calls `reschedule`/`cancel` to arm the
/// alarm, and the native alarm receiver calls back into `deliverDue` whenever
/// the Flutter engine is alive, so the send goes through the Dart pipeline
/// (BLoCs stay in sync, the chat re-renders) instead of the headless worker.
///
/// All outgoing calls are best-effort: on platforms without the channel (tests,
/// other OSes) the errors are swallowed so callers never need to guard.
class NativeScheduledSmsService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/scheduled_sms',
  );

  /// Invoked when the native alarm fires while the app is alive. The owner
  /// (`ScheduledMessageBloc`) runs a delivery sweep and re-arms the alarm.
  ///
  /// Must complete the sweep before returning: the native side falls back to
  /// its own headless delivery if this throws.
  Future<void> Function()? onDeliverDueRequested;

  /// Registers this instance as the handler for native → Dart calls.
  void startListening() {
    _channel.setMethodCallHandler((call) async {
      if (call.method != 'deliverDue') return null;
      final handler = onDeliverDueRequested;
      if (handler == null) {
        // Let the native side know it must deliver the messages itself.
        throw MissingPluginException('No deliverDue handler registered');
      }
      await handler();
      return true;
    });
  }

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
