import 'package:equatable/equatable.dart';

enum MessageType {
  sent,
  received,
}

enum MessageStatus {
  pending,
  sent,
  delivered,
  failed,
}

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
    );
  }

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
  final bool isPinned;

  const MessageThread({
    required this.threadId,
    required this.phoneNumber,
    this.contactId,
    this.contactName,
    required this.lastMessage,
    required this.lastMessageTime,
    this.unreadCount = 0,
    this.isPinned = false,
  });

  bool get hasUnread => unreadCount > 0;

  MessageThread copyWith({
    String? threadId,
    String? phoneNumber,
    String? contactId,
    String? contactName,
    String? lastMessage,
    DateTime? lastMessageTime,
    int? unreadCount,
    bool? isPinned,
  }) {
    return MessageThread(
      threadId: threadId ?? this.threadId,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      lastMessage: lastMessage ?? this.lastMessage,
      lastMessageTime: lastMessageTime ?? this.lastMessageTime,
      unreadCount: unreadCount ?? this.unreadCount,
      isPinned: isPinned ?? this.isPinned,
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
        isPinned,
      ];
}
























