import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

const _callChannel = MethodChannel('com.example.communication_super_app/call');
const _smsChannel = MethodChannel('com.example.communication_super_app/sms');

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;

  final calls = <MethodCall>[];

  tearDown(() {
    calls.clear();
    messenger.setMockMethodCallHandler(_callChannel, null);
    messenger.setMockMethodCallHandler(_smsChannel, null);
  });

  void handleCall(Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(_callChannel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  void handleSms(Future<Object?>? Function(MethodCall) handler) {
    messenger.setMockMethodCallHandler(_smsChannel, (call) {
      calls.add(call);
      return handler(call);
    });
  }

  group('NativeCallService', () {
    test('makeCall invokes "makeCall" with the phone argument', () async {
      handleCall((_) async => null);
      await NativeCallService.instance.makeCall('09120000000');

      expect(calls.single.method, 'makeCall');
      expect(calls.single.arguments, {
        'phone': '09120000000',
        'subscriptionId': -1,
      });
    });

    test('startDtmf forwards the digit, stopDtmf ends it', () async {
      handleCall((_) async => null);
      await NativeCallService.instance.startDtmf('5');
      await NativeCallService.instance.stopDtmf();

      expect(calls.map((c) => c.method), ['startDtmf', 'stopDtmf']);
      expect(calls.first.arguments, {'digit': '5'});
    });

    test('isInCall parses the native boolean result', () async {
      handleCall((call) async => call.method == 'isInCall' ? true : null);
      expect(await NativeCallService.instance.isInCall(), isTrue);
    });

    test('isInCall defaults to false when native returns null', () async {
      handleCall((_) async => null);
      expect(await NativeCallService.instance.isInCall(), isFalse);
    });
  });

  group('NativeSmsService.sendSms', () {
    test('sends "sendSms" with params and parses the result', () async {
      handleSms((call) async {
        if (call.method == 'sendSms') {
          return {
            'success': true,
            'phoneNumber': '09120000000',
            'messageLength': 5,
            'parts': 1,
            'subscriptionId': -1,
            'timestamp': 1700000000000,
          };
        }
        return null;
      });

      final result = await NativeSmsService().sendSms(
        phoneNumber: '09120000000',
        message: 'hello',
      );

      expect(calls.single.method, 'sendSms');
      expect(calls.single.arguments, {
        'phoneNumber': '09120000000',
        'message': 'hello',
        'subscriptionId': -1,
        'trackingId': '',
        // Delivery reports are on unless «گزارش تحویل» is switched off.
        'deliveryReport': true,
      });
      expect(result.success, isTrue);
      expect(result.timestamp, 1700000000000);
    });

    test('throws ArgumentError on an empty phone number', () async {
      handleSms((_) async => null);
      expect(
        () => NativeSmsService().sendSms(phoneNumber: '', message: 'hi'),
        throwsArgumentError,
      );
    });

    test('rethrows a native PlatformException (e.g. NO_SIM_CARD)', () async {
      handleSms((_) async {
        throw PlatformException(code: 'NO_SIM_CARD', message: 'no sim');
      });

      expect(
        () => NativeSmsService().sendSms(
          phoneNumber: '09120000000',
          message: 'hi',
        ),
        throwsA(
          isA<PlatformException>().having((e) => e.code, 'code', 'NO_SIM_CARD'),
        ),
      );
    });
  });
}
