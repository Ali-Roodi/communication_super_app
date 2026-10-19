import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Android's own blocked list (`BlockedNumberContract`, native
/// `SystemBlockList`) — what telecom, the SMS framework and every other app
/// consult. Only the default dialer / SMS app may use it; without either role
/// every call answers "nothing" and blocking stays app-only.
///
/// Never throws: the blocked list must keep working in the app whatever the
/// platform answers.
class SystemBlockList {
  const SystemBlockList();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/blocked',
  );

  Future<bool> available() async {
    try {
      return await _channel.invokeMethod<bool>('available') ?? false;
    } catch (e) {
      debugPrint('blocked list availability unknown: $e');
      return false;
    }
  }

  /// Every number on the list, as it was entered.
  Future<List<String>> list() async {
    try {
      return (await _channel.invokeListMethod<String>('list')) ?? const [];
    } catch (e) {
      debugPrint('blocked list read failed: $e');
      return const [];
    }
  }

  /// Adds [numbers]; answers the ones that are on the list afterwards.
  Future<List<String>> add(List<String> numbers) async {
    if (numbers.isEmpty) return const [];
    try {
      return (await _channel.invokeListMethod<String>('add', {
            'numbers': numbers,
          })) ??
          const [];
    } catch (e) {
      debugPrint('blocked list write failed: $e');
      return const [];
    }
  }

  /// Takes [numbers] off the list, in whatever format they were entered.
  /// False when the list could not be written (no role, or the platform
  /// refused) — the caller keeps the removal pending.
  Future<bool> remove(List<String> numbers) async {
    if (numbers.isEmpty) return true;
    try {
      final removed = await _channel.invokeMethod<int>('remove', {
        'numbers': numbers,
      });
      return removed != null && removed >= 0;
    } catch (e) {
      debugPrint('blocked list unblock failed: $e');
      return false;
    }
  }
}
