import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Deep links from native notifications into the app.
///
/// An SMS notification (posted natively by `SmsNotifier`) launches
/// MainActivity with a `threadId` extra:
/// - **Cold start** — the extra sits on the launch intent; call
///   [consumeInitialThreadId] once the UI is ready.
/// - **Warm start** — MainActivity.onNewIntent pushes the id through
///   `openThread`; register [onOpenThread] to receive it.
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/intents',
  );

  /// Called when a notification is tapped while the app is alive.
  void Function(String threadId)? onOpenThread;

  bool _handlerRegistered = false;

  /// Registers the warm-start handler. Idempotent.
  void registerHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openThread') {
        final threadId = call.arguments as String?;
        if (threadId != null && threadId.isNotEmpty) {
          onOpenThread?.call(threadId);
        }
      }
    });
  }

  /// The `threadId` the app was launched with (notification tap on a dead
  /// process), or null. The native side clears it — safe to call repeatedly.
  Future<String?> consumeInitialThreadId() async {
    try {
      final id = await _channel.invokeMethod<String>('getInitialThreadId');
      return (id != null && id.isNotEmpty) ? id : null;
    } catch (e) {
      debugPrint('consumeInitialThreadId failed: $e');
      return null;
    }
  }

  /// Tells the native notifier which conversation is on screen (null = none):
  /// notifications for the visible thread are suppressed while the app is
  /// foreground. Call with the threadId on enter and null on leave.
  Future<void> setVisibleThread(String? threadId) async {
    try {
      await _channel.invokeMethod('setVisibleThread', threadId);
    } catch (e) {
      debugPrint('setVisibleThread failed: $e');
    }
  }

  /// Dismisses this thread's SMS notifications (the user just opened it).
  Future<void> clearThreadNotifications(String threadId) async {
    try {
      await _channel.invokeMethod('clearThreadNotifications', threadId);
    } catch (e) {
      debugPrint('clearThreadNotifications failed: $e');
    }
  }
}
