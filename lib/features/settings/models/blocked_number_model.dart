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

  /// The canonical key for [phone] — **always the thread id that address would
  /// produce** — or empty when there is nothing to key on.
  ///
  /// This used to answer empty for any address holding no digits, on the
  /// reasoning that a digit-less string could never match a stored number. It
  /// can, and it is a large part of this inbox: an SMS from an **alphanumeric
  /// sender id** («همراه اول», `IRANCELL`, `Bank-Melli`) is delivered with that
  /// string as its address and `SmsService` stores it as the thread id verbatim
  /// — `PhoneNormalizer.toThreadId` returns the trimmed input for anything it
  /// cannot parse. So blocking one of those wrote **no row at all**
  /// ([BlockedNumbersRepository.block] returns null on an empty key) while the
  /// user got the confirmation dialog, the «مسدود شد» snack and the report
  /// checkbox for a block that had not happened: the conversation was still in
  /// the inbox on the way back and the next message from that sender still
  /// arrived. Plain numbers blocked correctly, which is exactly what made it
  /// look random.
  ///
  /// The rule is now the one the rest of the app already follows: **the blocked
  /// key is the thread id**, whatever shape the address has. The native
  /// `BlockedNumbers.normalizeToThreadId` has always answered the same way for
  /// these, so the receive-path check already matches what this now stores.
  /// Only a genuinely empty address answers empty.
  static String normalize(String phone) =>
      PhoneNormalizer.toThreadId(phone).trim();

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
