import 'package:equatable/equatable.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

/// The `messages.thread_id` of a group conversation.
///
/// A group thread id is `'g:' || groupId` — deliberately not a phone number, so
/// it can never collide with one, and deliberately still a plain `thread_id`, so
/// every query the inbox already runs (paging, pinning, archiving, the unread
/// count, the search) works on it without a single `if`.
///
/// Two consequences worth knowing:
/// * `PhoneNormalizer.toThreadId('g:…')` returns the string unchanged (it has no
///   digits to normalize), so passing a group id through the number helpers is
///   harmless rather than a crash — but nothing should *display* it.
/// * `blocked_numbers.normalized` only ever holds canonical numbers, so a group
///   thread can never be hidden by the inbox's block subquery.
class GroupThread {
  GroupThread._();

  static const String prefix = 'g:';

  /// Whether [threadId] names a group conversation rather than a number.
  static bool isGroup(String threadId) => threadId.startsWith(prefix);

  /// The thread id for [groupId].
  static String threadIdFor(String groupId) => '$prefix$groupId';

  /// The group id inside [threadId], or null when it is not a group thread.
  static String? groupIdOf(String threadId) =>
      isGroup(threadId) ? threadId.substring(prefix.length) : null;
}

/// One member of a group.
class GroupMember extends Equatable {
  const GroupMember({
    required this.phoneNumber,
    this.displayName,
    this.contactId,
  });

  /// The number as it should be dialled / addressed.
  final String phoneNumber;

  /// The contact name at the time the member was added, or null for an unsaved
  /// number. Denormalized so a group can be named before the address book has
  /// been read; refreshed opportunistically from the contact cache.
  final String? displayName;

  /// Device-contact id, when the member came from the address book. Not stored —
  /// it is only carried while a group is being assembled, so the picker can map
  /// a label's members back to rows.
  final String? contactId;

  /// The canonical key a member is identified and deduplicated by — the same
  /// `09xxxxxxxxx` form as `messages.thread_id`.
  String get normalized => PhoneNormalizer.toThreadId(phoneNumber);

  /// What to call this member on screen.
  String get label => (displayName != null && displayName!.trim().isNotEmpty)
      ? displayName!.trim()
      : PersianUtils.displayPhone(PhoneNormalizer.toNational(phoneNumber));

  /// The short form used inside a derived group title — a first name is enough
  /// to tell three people apart and a full title of full names does not fit.
  String get shortLabel {
    final full = label;
    final space = full.indexOf(' ');
    return space > 0 ? full.substring(0, space) : full;
  }

  GroupMember copyWith({String? displayName}) => GroupMember(
    phoneNumber: phoneNumber,
    displayName: displayName ?? this.displayName,
    contactId: contactId,
  );

  Map<String, Object?> toRow(String groupId, {DateTime? addedAt}) => {
    'group_id': groupId,
    'normalized': normalized,
    'phone_number': phoneNumber,
    'display_name': displayName,
    'added_at': (addedAt ?? DateTime.now()).millisecondsSinceEpoch,
  };

  factory GroupMember.fromRow(Map<String, Object?> row) => GroupMember(
    phoneNumber: row['phone_number'] as String,
    displayName: row['display_name'] as String?,
  );

  @override
  List<Object?> get props => [normalized, displayName];
}

/// A local group conversation.
class MessageGroup extends Equatable {
  const MessageGroup({
    required this.id,
    required this.members,
    this.title,
    required this.createdAt,
    required this.updatedAt,
  });

  final String id;

  /// The name the user gave the group, or null — in which case [displayTitle]
  /// derives one from the members, so renaming a contact renames the group.
  final String? title;

  final List<GroupMember> members;
  final DateTime createdAt;
  final DateTime updatedAt;

  String get threadId => GroupThread.threadIdFor(id);

  bool get hasTitle => title != null && title!.trim().isNotEmpty;

  /// «علی، مریم و رضا» / «علی، مریم و ۲ نفر دیگر» — Google Messages' derived
  /// group name.
  ///
  /// Everybody is named while everybody *fits*: a group of three is the common
  /// case and «علی، Khanoom و ۱ نفر دیگر» is a worse header than the third name
  /// itself. Past that the list would ellipsise, which tells the user nothing
  /// about who is in the group, so it becomes two names and a count.
  String get displayTitle {
    if (hasTitle) return title!.trim();
    if (members.isEmpty) return 'گروه';
    final names = [for (final m in members) m.shortLabel];
    if (names.length == 1) return names.first;
    if (names.length == 2) return '${names[0]} و ${names[1]}';
    if (names.length == 3) return '${names[0]}، ${names[1]} و ${names[2]}';
    final rest = names.length - 2;
    return '${names[0]}، ${names[1]} و '
        '${PersianUtils.toPersianNumber('$rest')} نفر دیگر';
  }

  /// «۴ نفر» — the subtitle under the header and the recipient count everywhere
  /// a send is priced.
  String get memberCountLabel =>
      '${PersianUtils.toPersianNumber('${members.length}')} نفر';

  /// The canonical member keys, for deduplicating a group against an existing
  /// one with the same people in it.
  Set<String> get memberKeys => {for (final m in members) m.normalized};

  MessageGroup copyWith({String? title, List<GroupMember>? members}) =>
      MessageGroup(
        id: id,
        title: title ?? this.title,
        members: members ?? this.members,
        createdAt: createdAt,
        updatedAt: updatedAt,
      );

  @override
  List<Object?> get props => [id, title, members, updatedAt];
}

/// Per-recipient outcome of one group send.
///
/// The bubble shows the aggregate («ارسال شد به ۳ از ۴»); this is what
/// «اطلاعات» lists, and what a retry re-sends — only the recipients that failed,
/// never the whole group again.
class GroupSendTarget extends Equatable {
  const GroupSendTarget({
    required this.messageId,
    required this.phoneNumber,
    required this.status,
    this.deviceSmsId,
    this.subscriptionId,
    this.trackingId,
  });

  final String messageId;
  final String phoneNumber;

  /// Same vocabulary as `MessageStatus.name` — pending / sent / delivered /
  /// failed. Kept as a string because this table is read by the aggregate
  /// helpers far more often than it is turned back into an enum.
  final String status;

  final int? deviceSmsId;
  final int? subscriptionId;
  final String? trackingId;

  String get normalized => PhoneNormalizer.toThreadId(phoneNumber);

  bool get failed => status == 'failed';
  bool get delivered => status == 'delivered';
  bool get pending => status == 'pending';

  Map<String, Object?> toRow() => {
    'message_id': messageId,
    'normalized': normalized,
    'phone_number': phoneNumber,
    'status': status,
    'device_sms_id': deviceSmsId,
    'subscription_id': subscriptionId,
    'tracking_id': trackingId,
  };

  factory GroupSendTarget.fromRow(Map<String, Object?> row) => GroupSendTarget(
    messageId: row['message_id'] as String,
    phoneNumber: row['phone_number'] as String,
    status: row['status'] as String,
    deviceSmsId: (row['device_sms_id'] as num?)?.toInt(),
    subscriptionId: (row['subscription_id'] as num?)?.toInt(),
    trackingId: row['tracking_id'] as String?,
  );

  @override
  List<Object?> get props => [
    messageId,
    normalized,
    status,
    deviceSmsId,
    subscriptionId,
    trackingId,
  ];
}

/// What one group send came to, folded into the single tick a bubble can show.
///
/// A group message has N outcomes and one bubble, and the fold has to be the
/// pessimistic one: a message that reached three of four people is **not**
/// «ارسال شد», because the one person it missed is the whole reason to look. So
/// the aggregate is the worst state any recipient is in, and the label says the
/// count out loud.
class GroupSendSummary {
  const GroupSendSummary({
    required this.total,
    required this.pending,
    required this.sent,
    required this.delivered,
    required this.failed,
  });

  factory GroupSendSummary.of(Iterable<GroupSendTarget> targets) {
    var pending = 0, sent = 0, delivered = 0, failed = 0;
    var total = 0;
    for (final target in targets) {
      total++;
      switch (target.status) {
        case 'pending':
          pending++;
        case 'delivered':
          delivered++;
        case 'failed':
          failed++;
        default:
          sent++;
      }
    }
    return GroupSendSummary(
      total: total,
      pending: pending,
      sent: sent,
      delivered: delivered,
      failed: failed,
    );
  }

  final int total;
  final int pending;
  final int sent;
  final int delivered;
  final int failed;

  bool get isEmpty => total == 0;

  /// How many recipients the radio accepted the message for.
  int get reached => sent + delivered;

  /// `MessageStatus.name` for the bubble's tick — worst-first.
  String get aggregateStatus {
    if (total == 0) return 'pending';
    if (pending > 0) return 'pending';
    if (failed == total) return 'failed';
    if (failed > 0) return 'failed';
    if (delivered == total) return 'delivered';
    return 'sent';
  }

  /// The sentence «اطلاعات» and the expanded bubble show.
  String get label {
    if (total == 0) return '';
    final all = PersianUtils.toPersianNumber('$total');
    if (pending > 0) {
      return 'در حال ارسال به $all نفر';
    }
    if (failed == total) return 'برای هیچ‌کس ارسال نشد';
    if (failed > 0) {
      final ok = PersianUtils.toPersianNumber('$reached');
      return 'ارسال شد به $ok از $all نفر';
    }
    if (delivered == total) return 'به $all نفر تحویل داده شد';
    return 'به $all نفر ارسال شد';
  }
}
