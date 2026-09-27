import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// The device's `ANDROID_ID`, over
/// `android/.../edition/DeviceIdentityHandler.kt`.
///
/// The value the inter-organizational activation code is bound to. It cannot
/// change while the process lives, so the first successful read is kept; a
/// failed read is not, so a transient channel failure gets another try.
class DeviceIdentityService {
  DeviceIdentityService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/device_identity',
  );

  String? _androidId;

  /// Null when the platform has no ANDROID_ID to give or the call failed —
  /// the caller cannot offer an activation then, and says so.
  Future<String?> androidId() async {
    final cached = _androidId;
    if (cached != null) return cached;
    try {
      final id = (await _channel.invokeMethod<String>('androidId'))?.trim();
      if (id == null || id.isEmpty) return null;
      return _androidId = id;
    } on PlatformException catch (e) {
      debugPrint('ANDROID_ID read failed: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }
}
