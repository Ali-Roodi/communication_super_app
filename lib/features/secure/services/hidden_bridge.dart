import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native half of «دفترچه مخفی» (`hidden/HiddenHandler.kt`). Dart owns
/// the phonebook, in `secure.db`; this tells Kotlin what it needs to act while
/// the section is **locked** — which numbers are hidden (kept as keyed tags,
/// never as numbers), the section's public key to seal records to, and, only
/// while the section is open, the names.
///
/// Every call swallows a missing plugin (tests, the commercial edition before
/// anything was hidden): nothing here is worth failing a screen over.
class HiddenBridge {
  const HiddenBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/hidden',
  );

  /// Replaces the hidden set. True when it changed — Kotlin has then swept
  /// the whole call log, so the caller drains the sealed calls.
  Future<bool> setNumbers(List<String> numbers) async =>
      await _call<bool>('setNumbers', {'numbers': numbers}) ?? false;

  /// Names for the call screen and notifications — process memory, while
  /// the section is open only.
  Future<void> setNames(Map<String, String> names) =>
      _call<void>('setNames', {'names': names});

  Future<void> clearNames() => _call<void>('clearNames');

  Future<void> setSealingKey(Uint8List publicKey) =>
      _call<void>('setSealingKey', {'public': publicKey});

  /// Moves hidden calls out of the system call log now; how many.
  Future<int> sweep({bool full = false}) async =>
      await _call<int>('sweep', {'full': full}) ?? 0;

  Future<bool> isHidden(String number) async =>
      await _call<bool>('isHidden', {'number': number}) ?? false;

  /// The section was deleted: nothing is hidden, nothing sealed can open.
  Future<void> forget() => _call<void>('forget');

  Future<void> clearMissedNotice() => _call<void>('clearMissedNotice');

  /// A scheduled message to a number hidden since it was scheduled: sent
  /// with no provider row, the copy sealed for the secure section.
  Future<bool> sendPrivately(
    String number,
    String body, {
    int? subscriptionId,
  }) async =>
      await _call<bool>('sendPrivately', {
        'number': number,
        'body': body,
        'subscriptionId': subscriptionId ?? -1,
      }) ??
      false;

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>(method, args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('Hidden bridge $method failed: ${e.code}');
      return null;
    } catch (e) {
      // No platform at all (a plain unit test): nothing is hidden there.
      return null;
    }
  }
}
