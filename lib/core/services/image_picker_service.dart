import 'package:flutter/services.dart';

/// Where a contact photo came from.
enum PhotoSource { gallery, camera }

/// A picked image, still full frame: the crop screen works on this and hands it
/// back to [ImagePickerService.crop].
class PickedImage {
  const PickedImage({
    required this.bytes,
    required this.width,
    required this.height,
  });

  /// JPEG bytes, downscaled by the native side and **already upright** — the
  /// EXIF orientation is applied on decode, so nothing downstream has to know
  /// that a portrait photo is stored as a landscape frame plus a tag.
  final Uint8List bytes;

  final int width;
  final int height;

  double get aspectRatio => height == 0 ? 1 : width / height;
}

/// Contact photos: pick one, then crop / rotate it.
///
/// A native channel rather than `image_picker` + `image_cropper`, for the
/// reason every other platform call in this app is one: those two plugins bring
/// the Kotlin Gradle Plugin this build already warns about, `image_cropper`
/// pulls a whole third-party crop Activity, and — the rule that actually
/// matters here — **a plugin that requests its own runtime permission is banned
/// in this app** (see the `call_log` / `another_telephony` crashes). The
/// platform's own `ACTION_GET_CONTENT` and `ACTION_IMAGE_CAPTURE` need no
/// permission at all when the app does not declare `CAMERA`.
class ImagePickerService {
  ImagePickerService._();
  static final ImagePickerService instance = ImagePickerService._();

  static const _channel = MethodChannel(
    'com.example.communication_super_app/media',
  );

  /// Opens the gallery chooser or the camera and returns the captured frame.
  /// Null when the user backed out.
  Future<PickedImage?> pick(PhotoSource source) async {
    final result = await _channel.invokeMapMethod<String, Object?>('pickImage', {
      'source': source == PhotoSource.camera ? 'camera' : 'gallery',
    });
    if (result == null) return null;
    final bytes = result['bytes'];
    if (bytes is! Uint8List || bytes.isEmpty) return null;
    return PickedImage(
      bytes: bytes,
      width: (result['width'] as num?)?.toInt() ?? 0,
      height: (result['height'] as num?)?.toInt() ?? 0,
    );
  }

  /// Rotates [bytes] by [rotation] degrees, cuts a **square** out of the
  /// rotated image and returns it as a small JPEG.
  ///
  /// The rectangle is normalised: [left] and [top] are fractions of the rotated
  /// image's width and height, [size] a fraction of its *shorter* edge. The crop
  /// screen works in its own layout units, and pixels would make the result
  /// depend on whatever preview size the native side happened to return.
  Future<Uint8List?> crop({
    required Uint8List bytes,
    required int rotation,
    required double left,
    required double top,
    required double size,
  }) async {
    return _channel.invokeMethod<Uint8List>('cropImage', {
      'bytes': bytes,
      'rotation': rotation,
      'left': left,
      'top': top,
      'size': size,
    });
  }

  /// Removes a contact's photo from the device address book.
  ///
  /// `flutter_contacts` cannot: setting `contact.photo = null` and updating
  /// writes nothing at all, so «حذف عکس» blanked the avatar on screen and the
  /// old picture came straight back on the next read. The photo is an ordinary
  /// Data row in the provider and the native side deletes it — on every raw
  /// contact behind the aggregate, because a linked contact has several.
  Future<bool> deleteContactPhoto(String contactId) async {
    if (contactId.isEmpty) return false;
    final ok = await _channel.invokeMethod<bool>('deleteContactPhoto', {
      'contactId': contactId,
    });
    return ok ?? false;
  }
}
