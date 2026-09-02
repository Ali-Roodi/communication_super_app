import 'package:equatable/equatable.dart';

import 'message_group.dart';

enum MessageType { sent, received }

enum MessageStatus { pending, sent, delivered, failed }

class MessageModel extends Equatable {
  final String id;
  final String threadId;
  final String? contactId;
  final String phoneNumber;
  final String body;
  final MessageType type;
  final MessageStatus status;
  final DateTime timestamp;
  final bool isRead;

  /// Row id of this message inside the device SMS provider (content://sms),
  /// when known. Set by the mirror-sync import and by the sent write-through;
  /// lets a delete remove the exact provider row. Null when unknown.
  final int? deviceSmsId;

  /// «ستاره‌دار» — a purely local bookmark. The mirror-sync inserts with
  /// `ConflictAlgorithm.ignore`, so re-importing a message never clears it.
  final bool isStarred;

  /// Subscription id of the SIM this message travelled on.
  ///
  /// **Null means unknown, never "SIM 1".** Every row that predates dual-SIM
  /// support is null, and so is any provider row the carrier or the OEM left
  /// unstamped — the UI omits the badge rather than guessing, because a wrong
  /// SIM on a message is worse than no SIM.
  final int? subscriptionId;

  const MessageModel({
    required this.id,
    required this.threadId,
    this.contactId,
    required this.phoneNumber,
    required this.body,
    required this.type,
    required this.status,
    required this.timestamp,
    this.isRead = false,
    this.deviceSmsId,
    this.isStarred = false,
    this.subscriptionId,
  });

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'thread_id': threadId,
      'contact_id': contactId,
      'phone_number': phoneNumber,
      'body': body,
      'type': type.name,
      'status': status.name,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'is_read': isRead ? 1 : 0,
      'device_sms_id': deviceSmsId,
      'is_starred': isStarred ? 1 : 0,
      'subscription_id': subscriptionId,
    };
  }

  factory MessageModel.fromMap(Map<String, dynamic> map) {
    return MessageModel(
      id: map['id'] as String,
      threadId: map['thread_id'] as String,
      contactId: map['contact_id'] as String?,
      phoneNumber: map['phone_number'] as String,
      body: map['body'] as String,
      type: MessageType.values.firstWhere(
        (e) => e.name == map['type'],
        orElse: () => MessageType.received,
      ),
      status: MessageStatus.values.firstWhere(
        (e) => e.name == map['status'],
        orElse: () => MessageStatus.sent,
      ),
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      isRead: (map['is_read'] as int?) == 1,
      deviceSmsId: (map['device_sms_id'] as num?)?.toInt(),
      isStarred: (map['is_starred'] as int?) == 1,
      subscriptionId: (map['subscription_id'] as num?)?.toInt(),
    );
  }

  /// Carries **every** field forward.
  ///
  /// Callers must use this rather than rebuilding a `MessageModel` by hand:
  /// two places did (the delivery-report swap and the sent/received merge in
  /// `MessageBloc`) and both silently dropped whatever field was added last —
  /// most recently `subscriptionId`, so a bubble lost its SIM badge the moment
  /// its ✓✓ arrived and only got it back on the next read from the DB.
  /// [deviceSmsId] and [subscriptionId] are "fill in if known": passing null
  /// keeps whatever the row already had rather than clearing it. That is what
  /// the send path wants — the native side answers -1/0 for "the platform did
  /// not say", and forgetting the value the caller asked for would be worse
  /// than keeping it.
  MessageModel copyWith({
    bool? isStarred,
    MessageStatus? status,
    bool? isRead,
    DateTime? timestamp,
    int? deviceSmsId,
    int? subscriptionId,
  }) => MessageModel(
    id: id,
    threadId: threadId,
    contactId: contactId,
    phoneNumber: phoneNumber,
    body: body,
    type: type,
    status: status ?? this.status,
    timestamp: timestamp ?? this.timestamp,
    isRead: isRead ?? this.isRead,
    deviceSmsId: deviceSmsId ?? this.deviceSmsId,
    isStarred: isStarred ?? this.isStarred,
    subscriptionId: subscriptionId ?? this.subscriptionId,
  );

  @override
  List<Object?> get props => [
    id,
    threadId,
    contactId,
    phoneNumber,
    body,
    type,
    status,
    timestamp,
    isRead,
    deviceSmsId,
    isStarred,
    subscriptionId,
  ];
}

class MessageThread extends Equatable {
  final String threadId;
  final String phoneNumber;
  final String? contactId;
  final String? contactName;
  final String lastMessage;
  final DateTime lastMessageTime;
  final int unreadCount;

  /// The user marked this conversation unread **by hand** — a mark, not a
  /// count.
  ///
  /// Kept apart from [unreadCount] because the two mean different things and
  /// the row draws them differently: a message that really arrived gets its
  /// number, a hand-mark gets a bare dot. Expressing the mark as an unread
  /// message row is exactly what made the two indistinguishable — see
  /// [MessageRepository.markThreadAsUnread].
  final bool manuallyUnread;

  final bool isPinned;

  /// Unsent composer text for this thread (shown as a «پیش‌نویس» preview and
  /// floats the row to the top). Null when there is no draft.
  final String? draftText;
  final DateTime? draftTime;

  /// The soonest queued outgoing message for this thread, shown as a
  /// «زمان‌بندی‌شده» preview and floating the row up exactly as a draft does.
  ///
  /// A scheduled send is an unfinished piece of the conversation, same as a
  /// draft — leaving the row wherever the last delivered message left it hides
  /// the one thing about that thread the user still has to think about.
  final String? scheduledText;
  final DateTime? scheduledTime;

  /// The group behind this row when [threadId] is a group thread (`'g:…'`).
  ///
  /// Resolved after the SQL — the group's members live in their own tables and
  /// the inbox query is deliberately blind to what kind of thread id it is
  /// paging (see [GroupThread]). Null for an ordinary conversation, and also for
  /// a group row read before the groups were resolved, so every reader falls
  /// back to [isGroup] rather than assuming this is populated.
  final MessageGroup? group;

  const MessageThread({
    required this.threadId,
    required this.phoneNumber,
    this.contactId,
    this.contactName,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.manuallyUnread = false,
    this.isPinned = false,
    this.draftText,
    this.draftTime,
    this.scheduledText,
    this.scheduledTime,
    this.group,
  });

  /// Whether this row is a group conversation — read from the thread id, so it
  /// is true even before [group] has been resolved.
  bool get isGroup => GroupThread.isGroup(threadId);

  /// Bold, and carrying a badge of some kind — either the count or the dot.
  bool get hasUnread => unreadCount > 0 || manuallyUnread;

  bool get hasDraft => draftText != null && draftText!.trim().isNotEmpty;

  bool get hasScheduled =>
      scheduledText != null && scheduledTime != null;

  /// Sort key: a fresh draft, or a queued send, lifts the row above older
  /// messages. A scheduled time is in the future, so such a row leads the
  /// inbox until it is delivered or cancelled — which is the point.
  DateTime get sortTime {
    var t = lastMessageTime;
    if (draftTime != null && draftTime!.isAfter(t)) t = draftTime!;
    if (scheduledTime != null && scheduledTime!.isAfter(t)) t = scheduledTime!;
    return t;
  }

  MessageThread copyWith({
    String? threadId,
    String? phoneNumber,
    String? contactId,
    String? contactName,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? manuallyUnread,
    bool? isPinned,
    String? draftText,
    DateTime? draftTime,
    String? scheduledText,
    DateTime? scheduledTime,
    MessageGroup? group,

    /// Drops the resolved contact name — this number belongs to nobody in the
    /// address book any more. A plain null cannot say it (every other field
    /// reads null as "leave it alone"), and a name that cannot *disappear* is
    /// how a deleted contact went on titling its conversation.
    bool clearContactName = false,
  }) {
    return MessageThread(
      threadId: threadId ?? this.threadId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      contactId: contactId ?? this.contactId,
      contactName: clearContactName
          ? null
          : (contactName ?? this.contactName),
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      manuallyUnread: manuallyUnread ?? this.manuallyUnread,
      isPinned: isPinned ?? this.isPinned,
      draftText: draftText ?? this.draftText,
      draftTime: draftTime ?? this.draftTime,
      scheduledText: scheduledText ?? this.scheduledText,
      scheduledTime: scheduledTime ?? this.scheduledTime,
      group: group ?? this.group,
    );
  }

  @override
  List<Object?> get props => [
    threadId,
    phoneNumber,
    contactId,
    contactName,
    lastMessage,
    lastMessageTime,
    unreadCount,
    manuallyUnread,
    isPinned,
    draftText,
    draftTime,
    scheduledText,
    scheduledTime,
    group,
  ];
}
