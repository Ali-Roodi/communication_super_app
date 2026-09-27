import 'package:flutter/services.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';

/// Why picking a key file failed.
enum KeyFilePickFailure { tooLarge, failed }

class KeyFilePickException implements Exception {
  const KeyFilePickException(this.failure);
  final KeyFilePickFailure failure;
  @override
  String toString() => 'KeyFilePickException($failure)';
}

/// Picks a key file (`.hkb`) through the system document picker, over
/// `…/key_file` (`smscrypto/KeyFilePicker.kt`). No permission is involved.
class KeyFileService {
  const KeyFileService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/key_file',
  );

  /// The file's bytes, or null when the user cancelled.
  Future<Uint8List?> pick() async {
    try {
      // A handoff: the picker is another app's screen, and neither the
      // secure section nor the app lock may close behind it.
      return await AppHandoff.run(
        () => _channel.invokeMethod<Uint8List>('pick'),
      );
    } on PlatformException catch (e) {
      throw KeyFilePickException(
        e.code == 'TOO_LARGE'
            ? KeyFilePickFailure.tooLarge
            : KeyFilePickFailure.failed,
      );
    } on MissingPluginException {
      throw const KeyFilePickException(KeyFilePickFailure.failed);
    }
  }
}
