import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

/// The number on the lock icon (`SecureLockButton`): encrypted messages —
/// and SMS from hidden contacts — the user has not looked at yet.
///
/// The mentor's ask: it stays until the messages are *seen*. Opening the app
/// or swiping «پیام رمز جدید» away does not clear it, and neither does
/// opening the section: a message is unread until its conversation is shown.
///
/// Two halves, because the section's own database is shut while it is
/// locked:
///  * what is still waiting in the native queues, which Kotlin counts
///    without opening anything ([DeepLinkService.pendingSecureMessages]);
///  * what was drained into `secure.db` and is still unread, as the section
///    last saw it while open ([remember], from `SecureMessagesBloc`). Only
///    the count is kept, in preferences: never a number, a name or a body.
class SecureUnreadBadge {
  SecureUnreadBadge._();

  /// What the badge shows; 0 hides it.
  static final ValueNotifier<int> count = ValueNotifier<int>(0);

  @visibleForTesting
  static const prefsKey = 'secure_unread_count';

  static Future<int> Function() _pending =
      DeepLinkService.instance.pendingSecureMessages;
  static StreamSubscription<void>? _arrivals;

  /// Reads both halves now and on every arrival. Idempotent.
  static void start() {
    _arrivals ??= NativeSmsService().onSecureArrived.listen((_) => refresh());
    unawaited(refresh());
  }

  /// Bumped per [refresh]: an answer that a newer one overtook is dropped.
  static int _seq = 0;

  static Future<void> refresh() async {
    final seq = ++_seq;
    try {
      final waiting = await _pending();
      final prefs = await SharedPreferences.getInstance();
      final drained = prefs.getInt(prefsKey) ?? 0;
      if (seq == _seq) count.value = waiting + drained;
    } catch (e) {
      debugPrint('Secure unread badge: ${e.runtimeType}');
    }
  }

  /// The section's unread count, as it stands after a reload.
  static Future<void> remember(int unread) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getInt(prefsKey) != unread) {
        await prefs.setInt(prefsKey, unread);
      }
    } catch (e) {
      debugPrint('Secure unread badge: ${e.runtimeType}');
    }
    await refresh();
  }

  /// The section was reset: none of what it held is unread any more.
  static Future<void> forget() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.remove(prefsKey);
    } catch (e) {
      debugPrint('Secure unread badge: ${e.runtimeType}');
    }
    await refresh();
  }

  @visibleForTesting
  static void debugSetPending(Future<int> Function() pending) {
    _pending = pending;
  }
}
