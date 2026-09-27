import 'dart:async';

import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final t0 = DateTime(2026, 9, 27, 12);

  test('an ordinary pause is not a handoff', () {
    final p = HandoffPause();
    expect(p.onPaused(t0), isFalse);
    expect(
      p.onResumed(t0.add(const Duration(seconds: 5))),
      HandoffResume.notHandoff,
    );
  });

  test(
    'a pause inside a handoff is excused when the app is back in time',
    () async {
      final p = HandoffPause();
      final picking = Completer<void>();
      final run = AppHandoff.run(() => picking.future);
      expect(AppHandoff.active, isTrue);
      // hidden, then paused: two events for one trip out.
      expect(p.onPaused(t0), isTrue);
      expect(p.onPaused(t0.add(const Duration(milliseconds: 10))), isTrue);
      // The picker returns before onResume, as on Android.
      picking.complete();
      await run;
      expect(AppHandoff.active, isFalse);
      expect(
        p.onResumed(t0.add(const Duration(seconds: 90))),
        HandoffResume.excused,
      );
      // The next, ordinary trip out is not excused by the last handoff.
      expect(p.onPaused(t0.add(const Duration(minutes: 5))), isFalse);
    },
  );

  test('a handoff that lasts too long locks on return', () async {
    final p = HandoffPause();
    await AppHandoff.run(() async {
      expect(p.onPaused(t0), isTrue);
    });
    expect(
      p.onResumed(t0.add(AppHandoff.maxAway + const Duration(seconds: 1))),
      HandoffResume.overdue,
    );
  });

  test(
    'a handoff started while the app is already away does not excuse it',
    () async {
      final p = HandoffPause();
      expect(p.onPaused(t0), isFalse);
      await AppHandoff.run(() async {
        expect(p.onPaused(t0.add(const Duration(seconds: 1))), isFalse);
      });
      expect(
        p.onResumed(t0.add(const Duration(seconds: 2))),
        HandoffResume.notHandoff,
      );
    },
  );

  test('a failing handoff still ends', () async {
    await expectLater(
      AppHandoff.run<void>(() async => throw StateError('picker failed')),
      throwsStateError,
    );
    expect(AppHandoff.active, isFalse);
  });
}
