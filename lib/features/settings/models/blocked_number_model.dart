import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

/// A blocked phone number, keyed by [normalized].
///
/// [normalized] is the **canonical thread id** (`09xxxxxxxxx`) — the same key
/// `messages.thread_id`, `PhoneNormalizer.toThreadId` and the native
/// `BlockedNumbers.normalizeToThreadId` produce.
///
/// It used to be a raw digits-only strip of whatever the caller passed, which is
/// why blocking did nothing at all: a number blocked from a conversation was
/// stored as `989121234567` (the address as the carrier delivered it) while
/// every lookup — Dart and Kotlin alike — asked for `09121234567`. The row was
/// there, the check never found it. Anything that writes or reads this column
/// must go through [normalize]; DB v16 rewrites the rows written before it.
class BlockedNumberModel extends Equatable {
  final String id;
  final String phoneNumber;
  final String normalized;
  final DateTime createdAt;

  /// Blocked *and reported as spam* («مسدود کردن و گزارش هرزنامه»), as opposed
  /// to plain blocked. Google Messages keeps the distinction: both land in the
  /// same list, only one of them is a report.
  final bool isSpam;

  /// When the number was reported, when it was. Null for a plain block.
  final DateTime? reportedAt;

  const BlockedNumberModel({
    required this.id,
    required this.phoneNumber,
    required this.normalized,
    required this.createdAt,
    this.isSpam = false,
    this.reportedAt,
  });

  /// The canonical key for [phone], or empty when [phone] holds no digits.
  ///
  /// The empty answer matters: `PhoneNormalizer.toThreadId` falls back to
  /// returning the trimmed input for a string it cannot parse, so without this
  /// guard «no-digits» would be stored as a blocked "number" that nothing can
  /// ever match. Callers treat empty as "not a number, do nothing".
  static String normalize(String phone) {
    if (!phone.contains(_anyDigit)) return '';
    return PhoneNormalizer.toThreadId(phone);
  }

  /// ASCII, Persian and Arabic-Indic digits — the same set `PhoneNormalizer`
  /// accepts.
  static final RegExp _anyDigit = RegExp(r'[\d۰-۹٠-٩]');

  Map<String, dynamic> toMap() => {
    'id': id,
    'phone_number': phoneNumber,
    'normalized': normalized,
    'created_at': createdAt.millisecondsSinceEpoch,
    'is_spam': isSpam ? 1 : 0,
    'reported_at': reportedAt?.millisecondsSinceEpoch,
  };

  factory BlockedNumberModel.fromMap(Map<String, dynamic> map) =>
      BlockedNumberModel(
        id: map['id'] as String,
        phoneNumber: map['phone_number'] as String,
        normalized: map['normalized'] as String,
        createdAt: DateTime.fromMillisecondsSinceEpoch(
          map['created_at'] as int,
        ),
        isSpam: ((map['is_spam'] as int?) ?? 0) == 1,
        reportedAt: map['reported_at'] == null
            ? null
            : DateTime.fromMillisecondsSinceEpoch(map['reported_at'] as int),
      );

  @override
  List<Object?> get props => [
    id,
    phoneNumber,
    normalized,
    createdAt,
    isSpam,
    reportedAt,
  ];
}
