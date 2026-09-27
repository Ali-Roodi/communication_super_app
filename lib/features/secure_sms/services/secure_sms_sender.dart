import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

/// Sends one encrypted packet as SMS. An interface so the engine is testable
/// without a radio.
abstract class SecureSmsSender {
  /// Sends [wire] to [phone]; [trackingId] comes back on the status stream.
  /// Throws when the SMS could not be handed to the radio.
  Future<void> send(String phone, String wire, {required String trackingId});
}

/// The real sender: the app's SMS channel, with `private` set so nothing is
/// written to `content://sms` (matrix row 11), and nothing to the main
/// database either — this path never goes near `SmsService`.
class NativeSecureSmsSender implements SecureSmsSender {
  NativeSecureSmsSender({NativeSmsService? native})
    : _native = native ?? NativeSmsService();

  final NativeSmsService _native;

  @override
  Future<void> send(
    String phone,
    String wire, {
    required String trackingId,
  }) async {
    await _native.sendSms(
      phoneNumber: phone,
      message: wire,
      trackingId: trackingId,
      private: true,
    );
  }
}
