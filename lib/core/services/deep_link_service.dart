import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// What an incoming intent asked the app to open.
///
/// Three kinds, and they all arrive through the same channel because they all
/// mean the same thing: *someone outside the app pointed at a screen inside it*.
enum LaunchActionType {
  /// An SMS notification tap — the conversation for a thread id.
  thread,

  /// A `tel:` intent (`ACTION_DIAL` / `ACTION_VIEW`): open the keypad with the
  /// number already in it. Delivered here because this app holds ROLE_DIALER.
  dial,

  /// An `sms:`/`smsto:` intent or a shared text: open the conversation with the
  /// body typed in. An empty [number] means "ask who to send it to".
  sms,
}

class LaunchAction {
  const LaunchAction({
    required this.type,
    this.threadId = '',
    this.number = '',
    this.body,
  });

  final LaunchActionType type;
  final String threadId;
  final String number;
  final String? body;

  static LaunchAction? fromMap(Object? raw) {
    if (raw is! Map) return null;
    final map = raw.cast<Object?, Object?>();
    final type = map['type'] as String?;
    switch (type) {
      case 'thread':
        final id = (map['threadId'] as String?) ?? '';
        if (id.isEmpty) return null;
        return LaunchAction(type: LaunchActionType.thread, threadId: id);
      case 'dial':
        final number = (map['number'] as String?) ?? '';
        if (number.isEmpty) return null;
        return LaunchAction(type: LaunchActionType.dial, number: number);
      case 'sms':
        return LaunchAction(
          type: LaunchActionType.sms,
          number: (map['number'] as String?) ?? '',
          body: map['body'] as String?,
        );
      default:
        return null;
    }
  }
}

/// Deep links from native notifications and from other apps' intents.
///
/// - **Cold start** — the intent sits on the launch intent; call
///   [consumeInitialAction] once the UI is ready.
/// - **Warm start** — MainActivity.onNewIntent pushes it through `openAction`;
///   register [onAction] to receive it.
///
/// The native side *consumes* what it hands over (the extra is removed, the
/// data URI cleared), so neither path can replay the same action on the next
/// resume — which would drop a keypad or a conversation on top of whatever the
/// user had opened since.
class DeepLinkService {
  DeepLinkService._();
  static final DeepLinkService instance = DeepLinkService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/intents',
  );

  /// Called when an intent arrives while the app is alive.
  void Function(LaunchAction action)? onAction;

  /// Called when a notification action («خواندم», «پاسخ», «مسدودسازی») has
  /// written a thread's rows natively while the app is alive — whatever is on
  /// screen was painted from the rows before it. See
  /// `MainActivity.notifyThreadChanged`.
  void Function(String threadId)? onThreadChanged;

  bool _handlerRegistered = false;

  /// Registers the warm-start handler. Idempotent.
  void registerHandler() {
    if (_handlerRegistered) return;
    _handlerRegistered = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'openAction') {
        final action = LaunchAction.fromMap(call.arguments);
        if (action != null) onAction?.call(action);
      } else if (call.method == 'threadChanged') {
        final threadId = call.arguments;
        if (threadId is String && threadId.isNotEmpty) {
          onThreadChanged?.call(threadId);
        }
      }
    });
  }

  /// The action the app was launched with (a notification tap or a `tel:` /
  /// `sms:` intent on a dead process), or null.
  Future<LaunchAction?> consumeInitialAction() async {
    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getInitialAction',
      );
      return LaunchAction.fromMap(raw);
    } catch (e) {
      debugPrint('consumeInitialAction failed: $e');
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

  /// Dismisses the missed-call notifications — and telecom's, which is what
  /// makes the OEM dialer drop its own duplicate. Called when «اخیر» is on
  /// screen: the user is looking at the list the notification points at.
  Future<void> clearMissedCallNotifications() async {
    try {
      await _channel.invokeMethod('clearMissedCallNotifications');
    } catch (e) {
      debugPrint('clearMissedCallNotifications failed: $e');
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

  /// Drops every SMS notification that no longer stands for something unread.
  ///
  /// The launcher badge is the count of the cards this app has posted, and a
  /// card is only cancelled where it was posted from — the conversation screen
  /// and the «خواندم» action. Everything else that ends an unread message
  /// (marking the thread read from the inbox, deleting it, blocking the sender,
  /// reading it on another device) used to leave the card and therefore the
  /// badge behind, with no way for the user to clear it by reading anything.
  /// Call after any of those, and on resume; it is a no-op when nothing is
  /// posted. See `SmsNotifier.reconcile`.
  Future<void> reconcileNotifications() async {
    try {
      await _channel.invokeMethod('reconcileNotifications');
    } catch (e) {
      debugPrint('reconcileNotifications failed: $e');
    }
  }
}
