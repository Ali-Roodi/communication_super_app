import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(
    'com.example.communication_super_app/sms_crypto',
  );
  const service = SmsCryptoService();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];

  void answer(Object? Function(MethodCall call) handler) {
    messenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call);
      return handler(call);
    });
  }

  Uint8List bytes(int n, int fill) => Uint8List(n)..fillRange(0, n, fill);

  setUp(calls.clear);
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('the prefix test mirrors Wire.PREFIX', () {
    expect(SmsCryptoService.looksEncrypted('#E:EfVPANLw'), isTrue);
    expect(SmsCryptoService.looksEncrypted('سلام #E:'), isFalse);
    expect(SmsCryptoService.looksEncrypted('#e:abc'), isFalse);
  });

  test('an identity comes back as its three parts', () async {
    answer(
      (_) => {
        'secret': bytes(97, 1),
        'public': bytes(1217, 2),
        'keyId': bytes(8, 3),
      },
    );
    final identity = await service.generateIdentity();
    expect(identity.secret.length, 97);
    expect(identity.publicKey.length, 1217);
    expect(identity.keyId, bytes(8, 3));
  });

  test(
    'encryptText sends the session and text, returns the next state',
    () async {
      answer((_) => {'session': bytes(99, 7), 'wire': '#E:abc', 'parts': 1});
      final sealed = await service.encryptText(
        session: bytes(99, 6),
        text: 'سلام',
      );
      expect(calls.single.method, 'encryptText');
      expect(calls.single.arguments, {
        'session': bytes(99, 6),
        'text': 'سلام',
        'deleteAfterSeen': false,
      });
      expect(sealed.state, bytes(99, 7));
      expect(sealed.wire, '#E:abc');
      expect(sealed.parts, 1);
    },
  );

  test(
    'certInitiate passes the busy session ids and returns the pending state',
    () async {
      answer(
        (_) => {'pending': bytes(64, 1), 'sid': 42, 'wire': '#E:x', 'parts': 2},
      );
      final started = await service.certInitiate(
        cert: bytes(103, 2),
        busySids: {7, 9},
      );
      expect(calls.single.method, 'certInitiate');
      expect((calls.single.arguments as Map)['busySids'], [7, 9]);
      expect((calls.single.arguments as Map)['cert'], bytes(103, 2));
      expect(started.state.length, 64);
      expect(started.sid, 42);
      expect(started.parts, 2);
    },
  );

  test('certRespond returns the session and the peer certificate', () async {
    answer(
      (_) => {
        'session': bytes(99, 1),
        'sid': 3,
        'wire': '#E:r',
        'parts': 2,
        'peer': {
          'cert': bytes(103, 4),
          'keyId': bytes(8, 5),
          'phone': '09121111111',
          'generation': 1,
        },
      },
    );
    final answered = await service.certRespond(
      secret: bytes(97, 1),
      cert: bytes(103, 2),
      text: '#E:init',
      anchors: [bytes(1985, 7)],
    );
    expect(calls.single.method, 'certRespond');
    expect(answered.sid, 3);
    expect(answered.parts, 2);
    expect(answered.peer.phone, '09121111111');
    expect(answered.peer.generation, 1);
    expect(answered.peer.keyId, bytes(8, 5));
  });

  test('every native error code maps to its failure', () async {
    const codes = {
      'NOT_OURS': SmsCryptoFailure.notOurs,
      'WRONG_TYPE': SmsCryptoFailure.wrongType,
      'BAD_KEY': SmsCryptoFailure.badKey,
      'WRONG_PEER': SmsCryptoFailure.wrongPeer,
      'NOT_FOR_US': SmsCryptoFailure.notForUs,
      'WRONG_SESSION': SmsCryptoFailure.wrongSession,
      'DUPLICATE': SmsCryptoFailure.duplicate,
      'TOO_FAR_AHEAD': SmsCryptoFailure.tooFarAhead,
      'AUTH_FAILED': SmsCryptoFailure.authFailed,
      'BAD_PAYLOAD': SmsCryptoFailure.badPayload,
      'REKEY_REQUIRED': SmsCryptoFailure.rekeyRequired,
      'NOT_A_KEY_FILE': SmsCryptoFailure.notAKeyFile,
      'WRONG_PASSWORD': SmsCryptoFailure.wrongPassword,
      'UNTRUSTED': SmsCryptoFailure.untrusted,
      'BAD_SIGNATURE': SmsCryptoFailure.badSignature,
      'BAD_BUNDLE': SmsCryptoFailure.badBundle,
      'BAD_ARGS': SmsCryptoFailure.failed,
      'FAILED': SmsCryptoFailure.failed,
    };
    for (final entry in codes.entries) {
      answer((_) => throw PlatformException(code: entry.key));
      await expectLater(
        service.decrypt(session: bytes(99, 0), text: '#E:abc'),
        throwsA(
          isA<SmsCryptoException>().having(
            (e) => e.failure,
            entry.key,
            entry.value,
          ),
        ),
      );
    }
  });

  test('inspect never throws: not ours is null', () async {
    expect(await service.inspect('سلام'), isNull);
    expect(calls, isEmpty); // no channel round trip for plain text

    answer((_) => null);
    expect(await service.inspect('#E:garbage'), isNull);

    answer((_) => throw PlatformException(code: 'FAILED'));
    expect(await service.inspect('#E:garbage'), isNull);

    answer(
      (_) => {
        'type': 'init',
        'sid': 5,
        'senderKid': bytes(8, 1),
        'certPhone': '09121111111',
        'certGeneration': 2,
      },
    );
    final info = await service.inspect('#E:init');
    expect(info!.type, SmsPacketType.init);
    expect(info.sid, 5);
    expect(info.counter, isNull);
    expect(info.senderKid, bytes(8, 1));
    expect(info.certPhone, '09121111111');
    expect(info.certGeneration, 2);
  });

  test('a key file comes back as its directory and the member key', () async {
    answer(
      (_) => {
        'signed': bytes(40, 1),
        'directory': {
          'authorityId': bytes(8, 2),
          'directoryId': bytes(8, 3),
          'serial': 1790000000000,
          'name': 'سازمان',
          'members': [
            {
              'name': 'علی',
              'phones': ['09121111111'],
              'public': bytes(32, 4),
              'keyId': bytes(8, 5),
            },
          ],
        },
        'member': {
          'index': 0,
          'secret': bytes(97, 6),
          'public': bytes(32, 4),
          'keyId': bytes(8, 5),
          'cert': {
            'cert': bytes(103, 8),
            'keyId': bytes(8, 5),
            'phone': '09121111111',
            'generation': 0,
          },
        },
      },
    );
    final opened = await service.openKeyFile(
      file: bytes(100, 0),
      password: 'pw',
      anchors: [bytes(1985, 7)],
    );
    expect((calls.single.arguments as Map)['anchors'], [bytes(1985, 7)]);
    expect(opened.directory.serial, 1790000000000);
    expect(opened.directory.members.single.phones, ['09121111111']);
    expect(opened.own!.index, 0);
    expect(opened.own!.identity.secret, bytes(97, 6));
    expect(opened.own!.cert.phone, '09121111111');
  });

  test('a key file without its certificate is refused', () async {
    answer(
      (_) => {
        'signed': bytes(40, 1),
        'directory': {
          'authorityId': bytes(8, 2),
          'directoryId': bytes(8, 3),
          'serial': 1,
          'name': 'سازمان',
          'members': <Map>[],
        },
        'member': {
          'index': 0,
          'secret': bytes(97, 6),
          'public': bytes(32, 4),
          'keyId': bytes(8, 5),
        },
      },
    );
    await expectLater(
      service.openKeyFile(file: bytes(100, 0), password: 'pw', anchors: []),
      throwsA(
        isA<SmsCryptoException>().having(
          (e) => e.failure,
          'failure',
          SmsCryptoFailure.badBundle,
        ),
      ),
    );
  });

  test('no native side at all is a failure, not a hang', () async {
    messenger.setMockMethodCallHandler(channel, null);
    await expectLater(
      service.generateIdentity(),
      throwsA(isA<SmsCryptoException>()),
    );
  });
}
