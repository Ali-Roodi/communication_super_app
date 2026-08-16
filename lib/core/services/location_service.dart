import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

/// Why a location read could not answer — each maps to one Persian sentence
/// the composer shows, because "نشد" alone leaves the user with nothing to do.
enum LocationFailure {
  /// The user refused, or has not been asked yet and refused the prompt.
  permissionDenied,

  /// Refused permanently — only the app's settings page can undo it.
  permissionPermanentlyDenied,

  /// Location services are off system-wide; a permission grant cannot fix it.
  disabled,

  /// Permission and services fine, no fix available (indoors, no signal).
  unavailable,
}

/// A coordinate pair, or the reason there isn't one.
class LocationResult {
  final double? latitude;
  final double? longitude;
  final double? accuracyMeters;
  final LocationFailure? failure;

  const LocationResult.success(
    this.latitude,
    this.longitude,
    this.accuracyMeters,
  ) : failure = null;

  const LocationResult.failed(this.failure)
    : latitude = null,
      longitude = null,
      accuracyMeters = null;

  bool get ok => failure == null;

  /// The text that goes into the message.
  ///
  /// Plain «lat, long» to six decimals — about 10 cm, past which the digits are
  /// noise. **ASCII digits and a LTR mark on purpose**: this is a coordinate
  /// pair the receiver will paste into a map, not prose, and Persian digits
  /// would be useless there. The LRM keeps the sign and the comma in order when
  /// the pair lands in the middle of an RTL sentence.
  String get messageText {
    final lat = latitude!.toStringAsFixed(6);
    final lng = longitude!.toStringAsFixed(6);
    return '‎$lat, $lng';
  }
}

/// Reads the device's location once, for «موقعیت» in the composer's attachment
/// sheet.
///
/// There is no tracking and no stream: one tap, one coordinate pair, inserted
/// into the message the user is writing. Nothing is stored and nothing is sent
/// anywhere except in the SMS the user chooses to send.
class LocationService {
  LocationService._();
  static final LocationService instance = LocationService._();

  static const _channel = MethodChannel(
    'com.example.communication_super_app/location',
  );

  /// Asks for the permission if needed, then reads one fix.
  Future<LocationResult> currentLocation() async {
    final status = await Permission.locationWhenInUse.request();
    if (status.isPermanentlyDenied) {
      return const LocationResult.failed(
        LocationFailure.permissionPermanentlyDenied,
      );
    }
    if (!status.isGranted && !status.isLimited) {
      return const LocationResult.failed(LocationFailure.permissionDenied);
    }

    try {
      final raw = await _channel.invokeMethod<Map<Object?, Object?>>(
        'getCurrentLocation',
      );
      if (raw == null) {
        return const LocationResult.failed(LocationFailure.unavailable);
      }
      final map = Map<String, dynamic>.from(raw);
      return LocationResult.success(
        (map['latitude'] as num).toDouble(),
        (map['longitude'] as num).toDouble(),
        (map['accuracy'] as num?)?.toDouble(),
      );
    } on PlatformException catch (e) {
      return LocationResult.failed(switch (e.code) {
        'PERMISSION_DENIED' => LocationFailure.permissionDenied,
        'LOCATION_DISABLED' => LocationFailure.disabled,
        _ => LocationFailure.unavailable,
      });
    } catch (_) {
      return const LocationResult.failed(LocationFailure.unavailable);
    }
  }

  /// The message shown when [currentLocation] could not answer.
  static String messageFor(LocationFailure failure) => switch (failure) {
    LocationFailure.permissionDenied =>
      'برای درج موقعیت، دسترسی موقعیت مکانی لازم است',
    LocationFailure.permissionPermanentlyDenied =>
      'دسترسی موقعیت مکانی رد شده است — از تنظیمات برنامه آن را روشن کنید',
    LocationFailure.disabled =>
      'موقعیت مکانی گوشی خاموش است — آن را روشن کنید و دوباره تلاش کنید',
    LocationFailure.unavailable =>
      'موقعیت مکانی پیدا نشد — کمی بعد امتحان کنید',
  };
}
