import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/secure/repositories/intruder_repository.dart';
import 'package:communication_super_app/features/security/models/device_security_report.dart';

void main() {
  final now = DateTime(2026, 10, 4);
  const healthy = <String, Object?>{
    'rootReasons': <String>[],
    'hooks': <String>[],
    'emulator': false,
    'adb': false,
    'developerOptions': false,
    'screenLock': true,
    'securityPatch': '2026-08-01',
    'sdk': 35,
    'release': '15',
    'debuggable': false,
    'debugger': false,
    'signature': 'release',
    'accessibility': <String>[],
    'encrypted': true,
    'keystore': 'tee',
    'defaultSms': true,
    'defaultDialer': true,
    'model': 'samsung SM-A336E',
  };

  group('DeviceSecurityReport (row 29)', () {
    test('a healthy phone has nothing above ok', () {
      final r = DeviceSecurityReport.fromFacts(healthy, now: now);
      expect(r.worst, SecurityLevel.ok);
      expect(r.count(SecurityLevel.risk), 0);
      expect(r.count(SecurityLevel.warn), 0);
    });

    test(
      'root, tampering or a foreign signer make it a risk, listed first',
      () {
        for (final bad in [
          {
            'rootReasons': ['su:/system/xbin/su'],
          },
          {
            'hooks': ['frida'],
          },
          {'signature': 'other'},
        ]) {
          final r = DeviceSecurityReport.fromFacts({
            ...healthy,
            ...bad,
          }, now: now);
          expect(r.worst, SecurityLevel.risk, reason: '$bad');
          expect(r.findings.first.level, SecurityLevel.risk);
        }
      },
    );

    test('weaker settings are warnings', () {
      final r = DeviceSecurityReport.fromFacts({
        ...healthy,
        'screenLock': false,
        'adb': true,
        'accessibility': ['Screen Reader X'],
        'securityPatch': '2024-01-05',
        'defaultSms': false,
        'keystore': 'software',
      }, now: now);
      expect(r.worst, SecurityLevel.warn);
      expect(r.count(SecurityLevel.warn), 6);
      expect(
        r.findings.any((f) => f.detail.contains('Screen Reader X')),
        isTrue,
      );
    });
  });

  group('IntruderRepository.parse (row 32)', () {
    Uint8List sealed(Map<String, Object?> header, List<int> jpeg) {
      final h = utf8.encode(jsonEncode(header));
      return Uint8List.fromList([
        (h.length >> 24) & 0xFF,
        (h.length >> 16) & 0xFF,
        (h.length >> 8) & 0xFF,
        h.length & 0xFF,
        ...h,
        ...jpeg,
      ]);
    }

    test('reads the header and the photo', () {
      final r = IntruderRepository.parse(
        sealed({'takenAt': 99, 'camera': 'front', 'failures': 3}, [0xFF, 0xD8]),
      )!;
      expect(r.takenAt, 99);
      expect(r.camera, 'front');
      expect(r.failures, 3);
      expect(r.jpeg, [0xFF, 0xD8]);
    });

    test('an attempt without a photo has no JPEG', () {
      final r = IntruderRepository.parse(
        sealed({'takenAt': 5, 'camera': 'none', 'failures': 6}, []),
      )!;
      expect(r.jpeg, isNull);
      expect(r.camera, 'none');
    });

    test('garbage is refused', () {
      expect(IntruderRepository.parse(Uint8List.fromList([0, 0])), isNull);
      expect(
        IntruderRepository.parse(Uint8List.fromList([0, 0, 0, 9, 1, 2])),
        isNull,
      );
      expect(
        IntruderRepository.parse(
          Uint8List.fromList([0, 0, 0, 2, ...utf8.encode('{x')]),
        ),
        isNull,
      );
    });
  });
}
