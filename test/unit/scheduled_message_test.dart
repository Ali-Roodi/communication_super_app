import 'package:flutter_test/flutter_test.dart';
import 'package:communication_super_app/features/messages/models/scheduled_message_model.dart';

ScheduledMessage _msg({
  required DateTime at,
  ScheduleRepeat repeat = ScheduleRepeat.none,
  int repeatEvery = 1,
  Set<int> weekdays = const {},
  ScheduleEnd endType = ScheduleEnd.never,
  DateTime? endDate,
  int? maxOccurrences,
  int occurrenceCount = 0,
  JitterWindow jitter = JitterWindow.none,
}) => ScheduledMessage(
  id: 's1',
  phoneNumber: '09120000000',
  body: 'سلام',
  scheduledAt: at,
  repeat: repeat,
  repeatEvery: repeatEvery,
  weekdays: weekdays,
  endType: endType,
  endDate: endDate,
  maxOccurrences: maxOccurrences,
  occurrenceCount: occurrenceCount,
  jitter: jitter,
  createdAt: DateTime(2026, 1, 1),
);

/// The instant the send happened — one minute after the nominal fire time, so
/// the catch-up walk in advanceAfterSend has nothing to skip.
final _sendTime = DateTime(2026, 6, 1, 9, 1);

void main() {
  group('ScheduledMessage.nextOccurrence', () {
    test('one-shot has no next occurrence', () {
      expect(_msg(at: DateTime(2026, 6, 1, 9)).nextOccurrence(), isNull);
    });

    test('daily advances by repeatEvery days, preserving time', () {
      final next = _msg(
        at: DateTime(2026, 6, 1, 9, 30),
        repeat: ScheduleRepeat.daily,
        repeatEvery: 3,
      ).nextOccurrence();
      expect(next, DateTime(2026, 6, 4, 9, 30));
    });

    test('weekly with no weekdays advances by 7×repeatEvery days', () {
      final next = _msg(
        at: DateTime(2026, 6, 1, 8),
        repeat: ScheduleRepeat.weekly,
        repeatEvery: 2,
      ).nextOccurrence();
      expect(next, DateTime(2026, 6, 15, 8));
    });

    test('weekly with weekdays jumps to the next selected weekday', () {
      // 2026-06-01 is a Monday (weekday 1). Selecting Wed(3)+Fri(5) → next is Wed.
      final next = _msg(
        at: DateTime(2026, 6, 1, 8),
        repeat: ScheduleRepeat.weekly,
        weekdays: {3, 5},
      ).nextOccurrence();
      expect(next, DateTime(2026, 6, 3, 8));
    });

    test('monthly clamps to the last valid day of a short month', () {
      // Jan 31 + 1 month → Feb 28 (2026 is not a leap year).
      final next = _msg(
        at: DateTime(2026, 1, 31, 10),
        repeat: ScheduleRepeat.monthly,
      ).nextOccurrence();
      expect(next, DateTime(2026, 2, 28, 10));
    });
  });

  group('ScheduledMessage.advanceAfterSend', () {
    test('one-shot completes after sending once', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
      ).advanceAfterSend(now: _sendTime);
      expect(m.status, ScheduleStatus.completed);
      expect(m.occurrenceCount, 1);
    });

    test('recurring stays pending with the next fire time', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
      ).advanceAfterSend(now: _sendTime);
      expect(m.status, ScheduleStatus.pending);
      expect(m.scheduledAt, DateTime(2026, 6, 2, 9));
      expect(m.occurrenceCount, 1);
    });

    test('afterCount end completes once the cap is reached', () {
      // maxOccurrences=2, already fired once → this (2nd) send completes it.
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
        endType: ScheduleEnd.afterCount,
        maxOccurrences: 2,
        occurrenceCount: 1,
      ).advanceAfterSend(now: _sendTime);
      expect(m.occurrenceCount, 2);
      expect(m.status, ScheduleStatus.completed);
    });

    test('onDate end completes when the next fire is past the end date', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
        endType: ScheduleEnd.onDate,
        endDate: DateTime(2026, 6, 1, 23),
      ).advanceAfterSend(now: _sendTime);
      // Next would be 2026-06-02 09:00, which is after the end date → completed.
      expect(m.status, ScheduleStatus.completed);
    });

    test('onDate end stays pending while the next fire is within range', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
        endType: ScheduleEnd.onDate,
        endDate: DateTime(2026, 6, 30, 23),
      ).advanceAfterSend(now: _sendTime);
      expect(m.status, ScheduleStatus.pending);
      expect(m.scheduledAt, DateTime(2026, 6, 2, 9));
    });
  });

  group('ScheduledMessage serialization', () {
    test('toMap/fromMap round-trips including weekdays and end condition', () {
      final original = _msg(
        at: DateTime(2026, 6, 1, 9, 15),
        repeat: ScheduleRepeat.weekly,
        repeatEvery: 2,
        weekdays: {6, 1, 3},
        endType: ScheduleEnd.afterCount,
        maxOccurrences: 5,
        occurrenceCount: 2,
      );
      final restored = ScheduledMessage.fromMap(original.toMap());
      expect(restored, original);
    });
  });

  group('ScheduledMessage.advanceAfterSend catch-up', () {
    test('skips occurrences missed while the device was off', () {
      // Daily at 09:00, last fired 2026-06-01, phone off until 2026-06-05 12:00.
      // The next fire must be 2026-06-06 09:00 — NOT four replayed sends.
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
      ).advanceAfterSend(now: DateTime(2026, 6, 5, 12));
      expect(m.status, ScheduleStatus.pending);
      expect(m.scheduledAt, DateTime(2026, 6, 6, 9));
      // Only one send happened, so the occurrence counter moves by one.
      expect(m.occurrenceCount, 1);
    });

    test('catch-up still honours the end date', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
        repeat: ScheduleRepeat.daily,
        endType: ScheduleEnd.onDate,
        endDate: DateTime(2026, 6, 3, 23),
      ).advanceAfterSend(now: DateTime(2026, 6, 5, 12));
      expect(m.status, ScheduleStatus.completed);
    });

    test('a successful send clears a previous failure', () {
      final m = _msg(at: DateTime(2026, 6, 1, 9), repeat: ScheduleRepeat.daily)
          .copyWith(
            attemptCount: 2,
            lastError: 'NO_SERVICE',
            nextAttemptAt: DateTime(2026, 6, 1, 9, 5),
          )
          .advanceAfterSend(now: _sendTime);
      expect(m.attemptCount, 0);
      expect(m.lastError, isNull);
      expect(m.nextAttemptAt, isNull);
    });
  });

  group('ScheduledMessage.withFailedAttempt', () {
    test('backs off and stays pending below the attempt cap', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 9),
      ).withFailedAttempt(errorCode: 'NO_SERVICE', now: _sendTime);
      expect(m.status, ScheduleStatus.pending);
      expect(m.attemptCount, 1);
      expect(m.lastError, 'NO_SERVICE');
      expect(m.nextAttemptAt, _sendTime.add(ScheduledMessage.retryDelay(1)));
    });

    test('fails permanently on the last attempt', () {
      final m = _msg(at: DateTime(2026, 6, 1, 9))
          .copyWith(attemptCount: ScheduledMessage.maxAttempts - 1)
          .withFailedAttempt(errorCode: 'NO_SIM_CARD', now: _sendTime);
      expect(m.status, ScheduleStatus.failed);
      expect(m.nextAttemptAt, isNull);
      expect(m.lastError, 'NO_SIM_CARD');
    });
  });

  group('ScheduledMessage.isDueAt', () {
    final now = DateTime(2026, 6, 1, 9);

    test('pending and past its time is due', () {
      expect(_msg(at: DateTime(2026, 6, 1, 8)).isDueAt(now), isTrue);
    });

    test('a future schedule is not due', () {
      expect(_msg(at: DateTime(2026, 6, 1, 10)).isDueAt(now), isFalse);
    });

    test('a pending retry is not due until its backoff elapses', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 8),
      ).copyWith(nextAttemptAt: DateTime(2026, 6, 1, 9, 30));
      expect(m.isDueAt(now), isFalse);
      expect(m.isDueAt(DateTime(2026, 6, 1, 9, 31)), isTrue);
    });

    test('a claimed (sending) row is not due', () {
      final m = _msg(
        at: DateTime(2026, 6, 1, 8),
      ).copyWith(status: ScheduleStatus.sending);
      expect(m.isDueAt(now), isFalse);
    });
  });

  group('ScheduledMessage jitter', () {
    final at = DateTime(2026, 6, 1, 9);

    test('no jitter sends exactly at the scheduled time', () {
      final m = _msg(at: at);
      expect(m.jitterOffset, Duration.zero);
      expect(m.effectiveSendAt, at);
      expect(m.isDueAt(at), isTrue);
    });

    test('the offset stays inside the window and never moves', () {
      final m = _msg(at: at, jitter: JitterWindow.thirtyMin);
      expect(m.jitterOffset.inMinutes, inInclusiveRange(0, 30));
      // Same row read twice (e.g. two deliverer ticks) must agree, otherwise a
      // message could slip past its window or fire early.
      expect(
        _msg(at: at, jitter: JitterWindow.thirtyMin).jitterOffset,
        m.jitterOffset,
      );
    });

    test('is not due before its jittered instant', () {
      final m = _msg(at: at, jitter: JitterWindow.sixtyMin);
      final offset = m.jitterOffset;
      if (offset > Duration.zero) {
        expect(m.isDueAt(at), isFalse);
        expect(m.isDueAt(at.add(offset - const Duration(minutes: 1))), isFalse);
      }
      expect(m.isDueAt(at.add(offset)), isTrue);
    });

    test('each occurrence of a repeat gets its own offset', () {
      final first = _msg(
        at: at,
        repeat: ScheduleRepeat.daily,
        jitter: JitterWindow.sixtyMin,
      );
      final second = first.copyWith(
        scheduledAt: at.add(const Duration(days: 1)),
        occurrenceCount: 1,
      );
      // Not a hard guarantee that they differ, but both must be in-window and
      // derived from the occurrence rather than fixed for the row.
      expect(second.jitterOffset.inMinutes, inInclusiveRange(0, 60));
      expect(
        second.effectiveSendAt.difference(second.scheduledAt),
        second.jitterOffset,
      );
    });
  });

  /// The jitter seed is a **cross-language contract**: `ScheduledSmsWorker.kt`
  /// re-implements it, and `ScheduledSmsScheduler` arms the alarm at the instant
  /// it produces. If the two ever disagree, the alarm wakes the phone at a moment
  /// the deliverer refuses, the row goes back to `pending`, and the message is
  /// late by up to the whole jitter window — silently.
  ///
  /// These vectors were produced by a *third*, independent implementation of
  /// FNV-1a, so they pin the value rather than whatever Dart happens to do.
  /// Kotlin must reproduce them exactly.
  group('ScheduledMessage.jitterSeed', () {
    test('matches the reference vectors', () {
      expect(
        ScheduledMessage.jitterSeed('a1b2c3', 1755500000000, 0),
        856208446,
      );
      expect(
        ScheduledMessage.jitterSeed('a1b2c3', 1755500000000, 3),
        3806098733,
      );
      expect(ScheduledMessage.jitterSeed('', 0, 0), 3795608245);
      // Non-ASCII: the id is hashed as UTF-16 code units, low byte first.
      expect(ScheduledMessage.jitterSeed('سلام', 1700000000000, 7), 387898163);
    });

    test('the offset is stable and inside the window', () {
      final at = DateTime.fromMillisecondsSinceEpoch(1755500000000);
      final message = ScheduledMessage(
        id: 'a1b2c3',
        phoneNumber: '09121234567',
        body: 'x',
        scheduledAt: at,
        jitter: JitterWindow.thirtyMin,
        createdAt: at,
      );
      expect(message.jitterOffset, message.jitterOffset);
      expect(message.jitterOffset.inMinutes, inInclusiveRange(0, 30));
      expect(message.effectiveSendAt, at.add(message.jitterOffset));
      // A different occurrence lands somewhere else in the window.
      expect(
        message.copyWith(occurrenceCount: 3).jitterOffset,
        isNot(message.jitterOffset),
      );
    });
  });
}
