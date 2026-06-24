import 'package:flutter/services.dart';

/// Picks an image from the device gallery via a native channel (no plugin
/// dependency). Returns downscaled JPEG bytes, or null if the user cancels.
class ImagePickerService {
  ImagePickerService._();
  static final ImagePickerService instance = ImagePickerService._();

  static const _channel = MethodChannel(
    'com.example.communication_super_app/media',
  );

  Future<Uint8List?> pickImage() async {
    final result = await _channel.invokeMethod<Uint8List>('pickImage');
    return result;
  }
}
