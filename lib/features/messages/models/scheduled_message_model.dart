import 'dart:math' as math;
import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

/// How a scheduled message repeats.
enum ScheduleRepeat {
  none('none'),
  daily('daily'),
  weekly('weekly'),
  monthly('monthly');

  const ScheduleRepeat(this.value);
  final String value;

  static ScheduleRepeat fromValue(String? v) => ScheduleRepeat.values
      .firstWhere((e) => e.value == v, orElse: () => ScheduleRepeat.none);
}

/// Send-time jitter window. The exact send time is spread inside the window so
/// a send doesn't land on the round minute it was scheduled for (and a
/// recurring batch doesn't fire at the exact same instant every time).
///
/// **Enforced, not informational** — on both deliverers. Dart gates on
/// [ScheduledMessage.effectiveSendAt] via `isDueAt`, and `ScheduledSmsWorker`
/// (Kotlin) applies the same gate before claiming a row. It applies to
/// one-shots too, which is why the sheet offers it independently of «تکرار».
enum JitterWindow {
  none('none', 0),
  tenMin('min10', 10),
  thirtyMin('min30', 30),
  sixtyMin('min60', 60);

  const JitterWindow(this.value, this.minutes);
  final String value;
  final int minutes;

  static JitterWindow fromValue(String? v) => JitterWindow.values.firstWhere(
    (e) => e.value == v,
    orElse: () => JitterWindow.none,
  );
}

/// When a recurring schedule stops.
enum ScheduleEnd {
  never('never'),
  onDate('onDate'),
  afterCount('afterCount');

  const ScheduleEnd(this.value);
  final String value;

  static ScheduleEnd fromValue(String? v) => ScheduleEnd.values.firstWhere(
    (e) => e.value == v,
    orElse: () => ScheduleEnd.never,
  );
}

enum ScheduleStatus {
  pending('pending'),

  /// Claimed by a deliverer and currently being sent. A row left in this state
  /// (process killed mid-send) is reclaimed after
  /// [ScheduledMessage.staleClaimTimeout].
  sending('sending'),
  completed('completed'),
  cancelled('cancelled'),
  failed('failed');

  const ScheduleStatus(this.value);
  final String value;

  static ScheduleStatus fromValue(String? v) => ScheduleStatus.values
      .firstWhere((e) => e.value == v, orElse: () => ScheduleStatus.pending);
}

/// A queued outgoing SMS, optionally recurring.
class ScheduledMessage extends Equatable {
  final String id;
  final String phoneNumber;
  final String? contactName;
  final String body;

  /// Next nominal fire time. The delivery worker treats the message as due when
  /// `now >= scheduledAt`; recurrence advances this after each send.
  final DateTime scheduledAt;

  final ScheduleRepeat repeat;

  /// "Every N" units (e.g. every 2 weeks). Ignored for [ScheduleRepeat.none].
  final int repeatEvery;

  /// For weekly repeats: the selected weekdays (1 = Monday … 7 = Sunday). When
  /// empty, weekly repeats fall on the same weekday as [scheduledAt].
  final Set<int> weekdays;

  final JitterWindow jitter;

  final ScheduleEnd endType;
  final DateTime? endDate;
  final int? maxOccurrences;

  /// How many times this schedule has already fired.
  final int occurrenceCount;

  final ScheduleStatus status;
  final DateTime createdAt;

  /// Consecutive failed send attempts for the *current* occurrence. Reset to 0
  /// on a successful send.
  final int attemptCount;

  /// When a failed attempt may be retried. While set in the future the row is
  /// not due, even though `scheduledAt` has passed.
  final DateTime? nextAttemptAt;

  /// Error code of the last failed attempt (`NO_SERVICE`, `NO_SIM_CARD`, …).
  final String? lastError;

  const ScheduledMessage({
    required this.id,
    required this.phoneNumber,
    this.contactName,
    required this.body,
    required this.scheduledAt,
    this.repeat = ScheduleRepeat.none,
    this.repeatEvery = 1,
    this.weekdays = const {},
    this.jitter = JitterWindow.none,
    this.endType = ScheduleEnd.never,
    this.endDate,
    this.maxOccurrences,
    this.occurrenceCount = 0,
    this.status = ScheduleStatus.pending,
    required this.createdAt,
    this.attemptCount = 0,
    this.nextAttemptAt,
    this.lastError,
  });

  /// A row claimed longer ago than this is assumed abandoned (the process that
  /// claimed it was killed) and is released back to `pending`.
  static const Duration staleClaimTimeout = Duration(minutes: 2);

  /// Attempts before a schedule is given up on. Delays: 1 min, 5 min, then fail.
  static const int maxAttempts = 3;

  /// Backoff before retry number [attempt] (1-based).
  static Duration retryDelay(int attempt) =>
      attempt <= 1 ? const Duration(minutes: 1) : const Duration(minutes: 5);

  bool get isRecurring => repeat != ScheduleRepeat.none;

  /// Conversation this schedule belongs to — same normalization as
  /// `messages.thread_id`, so the chat screen can match them up.
  String get threadId => PhoneNormalizer.toThreadId(phoneNumber);

  /// Offset inside the [jitter] window for *this* occurrence.
  ///
  /// Derived from the id and the occurrence rather than rolled fresh, so every
  /// tick of the deliverer agrees on when the message goes out — a re-rolled
  /// offset would let a row slip past its window or fire early on the next
  /// tick. `ScheduledSmsScheduler` (native) spreads the alarm the same way; it
  /// picks its own point in the window, which is equally valid because the only
  /// contract is "somewhere inside the window".
  Duration get jitterOffset {
    if (jitter.minutes <= 0) return Duration.zero;
    final seed = Object.hash(
      id,
      scheduledAt.millisecondsSinceEpoch,
      occurrenceCount,
    );
    return Duration(minutes: seed.abs() % (jitter.minutes + 1));
  }

  /// When this occurrence actually goes out: its scheduled time plus the
  /// jitter offset.
  DateTime get effectiveSendAt => scheduledAt.add(jitterOffset);

  /// True when this schedule should be sent at [now]: still pending, its time
  /// (including any jitter) has arrived, and any retry backoff has elapsed.
  bool isDueAt(DateTime now) =>
      status == ScheduleStatus.pending &&
      !effectiveSendAt.isAfter(now) &&
      (nextAttemptAt == null || !nextAttemptAt!.isAfter(now));

  /// The next fire time strictly after [scheduledAt] per the repeat rule, or
  /// null if this is a one-shot schedule.
  DateTime? nextOccurrence() => _nextAfter(scheduledAt);

  DateTime? _nextAfter(DateTime from) {
    switch (repeat) {
      case ScheduleRepeat.none:
        return null;
      case ScheduleRepeat.daily:
        return from.add(Duration(days: repeatEvery));
      case ScheduleRepeat.weekly:
        if (weekdays.isEmpty) {
          return from.add(Duration(days: 7 * repeatEvery));
        }
        // Walk forward to the next selected weekday after `from`.
        for (var i = 1; i <= 7; i++) {
          final cand = from.add(Duration(days: i));
          if (weekdays.contains(cand.weekday)) {
            return DateTime(
              cand.year,
              cand.month,
              cand.day,
              from.hour,
              from.minute,
            );
          }
        }
        return null;
      case ScheduleRepeat.monthly:
        return _addMonths(from, repeatEvery);
    }
  }

  static DateTime _addMonths(DateTime d, int months) {
    final total = d.month - 1 + months;
    final year = d.year + total ~/ 12;
    final month = total % 12 + 1;
    final day = math.min(d.day, _daysInMonth(year, month));
    return DateTime(year, month, day, d.hour, d.minute);
  }

  static int _daysInMonth(int year, int month) {
    final firstNext = (month == 12)
        ? DateTime(year + 1, 1, 1)
        : DateTime(year, month + 1, 1);
    return firstNext.subtract(const Duration(days: 1)).day;
  }

  /// Returns this schedule advanced after a successful send: either the next
  /// pending occurrence, or a completed schedule when the recurrence is
  /// exhausted (non-recurring, end-date passed, or occurrence cap reached).
  ///
  /// Occurrences that were missed while the device was off are **skipped, not
  /// replayed**: the next fire time is walked forward until it is in the future
  /// relative to [now]. Without this a daily schedule missed for a week fires
  /// seven times in a row the moment the app opens.
  ScheduledMessage advanceAfterSend({DateTime? now}) {
    final at = now ?? DateTime.now();
    final newCount = occurrenceCount + 1;

    var next = _nextAfter(scheduledAt);
    // Skip every occurrence that is already in the past.
    var guard = 0;
    while (next != null && !next.isAfter(at) && guard++ < _maxSkipAhead) {
      final after = _nextAfter(next);
      if (after == null || after == next) break;
      next = after;
    }

    final exhausted =
        next == null ||
        (endType == ScheduleEnd.afterCount &&
            maxOccurrences != null &&
            newCount >= maxOccurrences!) ||
        (endType == ScheduleEnd.onDate &&
            endDate != null &&
            next.isAfter(endDate!));

    if (exhausted) {
      return copyWith(
        occurrenceCount: newCount,
        status: ScheduleStatus.completed,
        attemptCount: 0,
        clearNextAttemptAt: true,
        clearLastError: true,
      );
    }
    return copyWith(
      occurrenceCount: newCount,
      scheduledAt: next,
      attemptCount: 0,
      clearNextAttemptAt: true,
      clearLastError: true,
    );
  }

  /// Bounds the catch-up walk in [advanceAfterSend] so a pathological repeat
  /// rule can never spin (e.g. a `weekly` rule whose weekday set never matches).
  static const int _maxSkipAhead = 5000;

  /// Returns this schedule after a failed send attempt: either scheduled for a
  /// backoff retry, or permanently failed once [maxAttempts] is reached.
  ScheduledMessage withFailedAttempt({
    required String errorCode,
    DateTime? now,
  }) {
    final at = now ?? DateTime.now();
    final attempts = attemptCount + 1;
    if (attempts >= maxAttempts) {
      return copyWith(
        status: ScheduleStatus.failed,
        attemptCount: attempts,
        lastError: errorCode,
        clearNextAttemptAt: true,
      );
    }
    return copyWith(
      status: ScheduleStatus.pending,
      attemptCount: attempts,
      lastError: errorCode,
      nextAttemptAt: at.add(retryDelay(attempts)),
    );
  }

  /// Row for an INSERT-OR-REPLACE upsert.
  ///
  /// `claim_token` / `claimed_at` are deliberately absent: writing a row back
  /// through the repository always *releases* any claim it held, which is the
  /// correct outcome for every writer (send finished, user edited, cancelled).
  Map<String, dynamic> toMap() => {
    'id': id,
    'phone_number': phoneNumber,
    'contact_name': contactName,
    'body': body,
    'scheduled_at': scheduledAt.millisecondsSinceEpoch,
    'repeat': repeat.value,
    'repeat_every': repeatEvery,
    'weekdays': weekdays.isEmpty ? null : (weekdays.toList()..sort()).join(','),
    'jitter': jitter.value,
    'end_type': endType.value,
    'end_date': endDate?.millisecondsSinceEpoch,
    'max_occurrences': maxOccurrences,
    'occurrence_count': occurrenceCount,
    'status': status.value,
    'created_at': createdAt.millisecondsSinceEpoch,
    'attempt_count': attemptCount,
    'next_attempt_at': nextAttemptAt?.millisecondsSinceEpoch,
    'last_error': lastError,
  };

  factory ScheduledMessage.fromMap(Map<String, dynamic> m) => ScheduledMessage(
    id: m['id'] as String,
    phoneNumber: m['phone_number'] as String,
    contactName: m['contact_name'] as String?,
    body: m['body'] as String,
    scheduledAt: DateTime.fromMillisecondsSinceEpoch(m['scheduled_at'] as int),
    repeat: ScheduleRepeat.fromValue(m['repeat'] as String?),
    repeatEvery: (m['repeat_every'] as int?) ?? 1,
    weekdays: _parseWeekdays(m['weekdays'] as String?),
    jitter: JitterWindow.fromValue(m['jitter'] as String?),
    endType: ScheduleEnd.fromValue(m['end_type'] as String?),
    endDate: (m['end_date'] as int?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(m['end_date'] as int),
    maxOccurrences: m['max_occurrences'] as int?,
    occurrenceCount: (m['occurrence_count'] as int?) ?? 0,
    status: ScheduleStatus.fromValue(m['status'] as String?),
    createdAt: DateTime.fromMillisecondsSinceEpoch(m['created_at'] as int),
    attemptCount: (m['attempt_count'] as int?) ?? 0,
    nextAttemptAt: (m['next_attempt_at'] as int?) == null
        ? null
        : DateTime.fromMillisecondsSinceEpoch(m['next_attempt_at'] as int),
    lastError: m['last_error'] as String?,
  );

  static Set<int> _parseWeekdays(String? csv) {
    if (csv == null || csv.isEmpty) return const {};
    return csv
        .split(',')
        .map((s) => int.tryParse(s.trim()))
        .whereType<int>()
        .toSet();
  }

  ScheduledMessage copyWith({
    String? phoneNumber,
    String? contactName,
    String? body,
    DateTime? scheduledAt,
    ScheduleRepeat? repeat,
    int? repeatEvery,
    Set<int>? weekdays,
    JitterWindow? jitter,
    ScheduleEnd? endType,
    DateTime? endDate,
    int? maxOccurrences,
    int? occurrenceCount,
    ScheduleStatus? status,
    int? attemptCount,
    DateTime? nextAttemptAt,
    String? lastError,
    bool clearNextAttemptAt = false,
    bool clearLastError = false,
  }) => ScheduledMessage(
    id: id,
    phoneNumber: phoneNumber ?? this.phoneNumber,
    contactName: contactName ?? this.contactName,
    body: body ?? this.body,
    scheduledAt: scheduledAt ?? this.scheduledAt,
    repeat: repeat ?? this.repeat,
    repeatEvery: repeatEvery ?? this.repeatEvery,
    weekdays: weekdays ?? this.weekdays,
    jitter: jitter ?? this.jitter,
    endType: endType ?? this.endType,
    endDate: endDate ?? this.endDate,
    maxOccurrences: maxOccurrences ?? this.maxOccurrences,
    occurrenceCount: occurrenceCount ?? this.occurrenceCount,
    status: status ?? this.status,
    createdAt: createdAt,
    attemptCount: attemptCount ?? this.attemptCount,
    nextAttemptAt: clearNextAttemptAt
        ? null
        : (nextAttemptAt ?? this.nextAttemptAt),
    lastError: clearLastError ? null : (lastError ?? this.lastError),
  );

  @override
  List<Object?> get props => [
    id,
    phoneNumber,
    contactName,
    body,
    scheduledAt,
    repeat,
    repeatEvery,
    weekdays,
    jitter,
    endType,
    endDate,
    maxOccurrences,
    occurrenceCount,
    status,
    createdAt,
    attemptCount,
    nextAttemptAt,
    lastError,
  ];
}
