import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The native half of «کنترل امنیت سامانه» (row 29) and «عکس از ورود
/// ناموفق» (row 32): `security.*` methods on the secure section's channel
/// (`HiddenHandler` → `SecurityHandler.kt`).
///
/// Every call swallows a missing plugin (tests): nothing here is worth
/// failing a screen — or a PIN check — over.
class SecurityBridge {
  const SecurityBridge();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/hidden',
  );

  Future<Map<String, Object?>?> deviceReport() async {
    final m = await _call<Map>('deviceReport');
    return m?.cast<String, Object?>();
  }

  Future<({bool enabled, bool camera})> intruderStatus() async {
    final m = await _call<Map>('intruderStatus');
    return (enabled: m?['enabled'] == true, camera: m?['camera'] == true);
  }

  Future<void> setIntruderEnabled(bool enabled) =>
      _call<void>('setIntruderEnabled', {'enabled': enabled});

  /// A wrong app PIN; [failures] in a row so far.
  Future<void> wrongPin(int failures) =>
      _call<void>('wrongPin', {'failures': failures});

  /// Failed-entry events since the report was last shown.
  Future<({int events, int lastAt})> intruderReport() async {
    final m = await _call<Map>('intruderReport');
    return (
      events: (m?['events'] as num?)?.toInt() ?? 0,
      lastAt: (m?['lastAt'] as num?)?.toInt() ?? 0,
    );
  }

  Future<void> clearIntruderReport() => _call<void>('clearIntruderReport');

  /// Sealed photos waiting for the section.
  Future<List<({String name, Uint8List blob})>> intruderFiles() async {
    final list = await _call<List>('intruderFiles') ?? const [];
    return [
      for (final e in list.cast<Map>())
        (name: e['name'] as String, blob: e['blob'] as Uint8List),
    ];
  }

  Future<void> deleteIntruderFiles(List<String> names) =>
      _call<void>('deleteIntruderFiles', {'names': names});

  Future<T?> _call<T>(String method, [Map<String, Object?>? args]) async {
    try {
      return await _channel.invokeMethod<T>('security.$method', args);
    } on MissingPluginException {
      return null;
    } on PlatformException catch (e) {
      debugPrint('Security bridge $method failed: ${e.code}');
      return null;
    } catch (e) {
      // No platform at all (a plain unit test): the PIN check goes on.
      return null;
    }
  }
}
