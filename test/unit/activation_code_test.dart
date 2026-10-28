import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:flutter_test/flutter_test.dart';

/// (ANDROID_ID, device code, activation code) as computed by the earlier S2MS
/// app's own `Activation.uniqueCode` / `Activation.checkCode` logic and its
/// `Blake3.java`, compiled and run as-is — the implementation the mentor's
/// Windows generator agrees with. If any of these changes, codes the generator
/// has already issued stop working.
const _reference = [
  ('9774d56d682e549c', '10e9fa', 'ba57b3b74f'),
  ('a1b2c3d4e5f60718', '5cd04a', '875e3c4ba5'),
  ('0000000000000000', '65a992', '57a1ce9d4c'),
  ('ffffffffffffffff', '806736', 'a5808f8364'),
  ('3f6c1e0b9a27d845', '33b957', '0c310a2277'),
];

const _inter = ActivationTarget.interOrganization;
const _org = ActivationTarget.organization;

/// The organization APK's codes for the same device codes. Ours, not the
/// mentor's; pinned to the same values in `tools/keybank`'s `ActivationTest`,
/// whose BLAKE3 is Bouncy Castle's — two implementations agreeing.
const _organization = [
  ('10e9fa', '2e68ceefcf'),
  ('5cd04a', '16e4d9c787'),
  ('65a992', '3496a31e3a'),
  ('806736', 'b0c1e7c455'),
  ('33b957', 'a3d4ec8c14'),
  ('b60966', 'f87be27c18'),
];

final String _zwnj = String.fromCharCode(0x200C);
final String _lrm = String.fromCharCode(0x200E);

void main() {
  group('matches the Java reference', () {
    for (final (androidId, deviceCode, activationCode) in _reference) {
      test('ANDROID_ID $androidId', () {
        expect(ActivationCode.deviceCodeFor(androidId), deviceCode);
        expect(
          ActivationCode.activationCodeFor(deviceCode, target: _inter),
          activationCode,
        );
        expect(
          ActivationCode.matches(
            deviceCode: deviceCode,
            input: activationCode,
            target: _inter,
          ),
          isTrue,
        );
      });
    }
  });

  test('codes have the documented shape', () {
    final device = ActivationCode.deviceCodeFor('9774d56d682e549c');
    expect(device, matches(RegExp(r'^[0-9a-f]{6}$')));
    expect(
      ActivationCode.activationCodeFor(device, target: _inter),
      matches(RegExp(r'^[0-9a-f]{10}$')),
    );
  });

  group('normalize — the code is typed by hand after being read aloud', () {
    test('upper case, spaces and dashes are forgiven', () {
      expect(ActivationCode.normalize('0C31-0A22 77'), '0c310a2277');
      expect(ActivationCode.normalize('  0c310a2277  '), '0c310a2277');
    });

    test('Persian and Arabic-Indic digits are read as digits', () {
      expect(ActivationCode.normalize('۰c۳۱۰a۲۲۷۷'), '0c310a2277');
      expect(ActivationCode.normalize('٠c٣١٠a٢٢٧٧'), '0c310a2277');
    });

    test('invisible marks a Persian keyboard slips in are dropped', () {
      expect(
        ActivationCode.normalize('$_lrm${'0c310'}$_zwnj${'a2277'}'),
        '0c310a2277',
      );
    });

    test('anything that cannot be a code is null', () {
      expect(ActivationCode.normalize(''), isNull);
      expect(ActivationCode.normalize('0c310a227'), isNull); // 9
      expect(ActivationCode.normalize('0c310a22770'), isNull); // 11
      expect(ActivationCode.normalize('0c310a227g'), isNull); // not hex
      expect(ActivationCode.normalize('کد۰c۳۱۰a۲۲۷۷'), isNull);
    });
  });

  group('matches', () {
    test('a tolerant spelling of the right code is accepted', () {
      expect(
        ActivationCode.matches(
          deviceCode: '33b957',
          input: '0C31-0A22-77',
          target: _inter,
        ),
        isTrue,
      );
    });

    test('another device\'s code is rejected', () {
      expect(
        ActivationCode.matches(
          deviceCode: '33b957',
          input: 'ba57b3b74f',
          target: _inter,
        ),
        isFalse,
      );
    });

    test('a one-character change is rejected', () {
      expect(
        ActivationCode.matches(
          deviceCode: '33b957',
          input: '0c310a2276',
          target: _inter,
        ),
        isFalse,
      );
    });

    test('malformed input or device code is rejected, never thrown', () {
      expect(
        ActivationCode.matches(deviceCode: '33b957', input: '', target: _inter),
        isFalse,
      );
      expect(
        ActivationCode.matches(
          deviceCode: '33b95',
          input: '0c310a2277',
          target: _inter,
        ),
        isFalse,
      );
    });
  });

  test('activationCodeFor refuses a device code of the wrong length', () {
    // Activation.checkCode answers false for one (index out of range).
    expect(
      () => ActivationCode.activationCodeFor('33b95', target: _inter),
      throwsArgumentError,
    );
    expect(
      () => ActivationCode.activationCodeFor('33b9577', target: _inter),
      throwsArgumentError,
    );
  });

  group('the organization target', () {
    for (final (deviceCode, code) in _organization) {
      test('device $deviceCode', () {
        expect(
          ActivationCode.activationCodeFor(deviceCode, target: _org),
          code,
        );
        expect(
          ActivationCode.matches(
            deviceCode: deviceCode,
            input: code,
            target: _org,
          ),
          isTrue,
        );
      });
    }

    test('a code for one edition never opens the other', () {
      for (final (_, deviceCode, interCode) in _reference) {
        final orgCode = ActivationCode.activationCodeFor(
          deviceCode,
          target: _org,
        );
        expect(orgCode, isNot(interCode));
        expect(
          ActivationCode.matches(
            deviceCode: deviceCode,
            input: interCode,
            target: _org,
          ),
          isFalse,
        );
        expect(
          ActivationCode.matches(
            deviceCode: deviceCode,
            input: orgCode,
            target: _inter,
          ),
          isFalse,
        );
      }
    });

    test('the app ids are the documented ones', () {
      expect(_inter.appId, '111111'); // the mentor's generator — fixed
      expect(_org.appId, '222222');
      expect(ActivationTarget.ofBuild, _inter); // a test run is commercial
    });
  });
}
