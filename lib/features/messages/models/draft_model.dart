import 'package:equatable/equatable.dart';

/// A saved message draft. [title] is an organisational label only — it is NOT
/// sent with the message (Figma: «عنوان (همراه پیام ارسال نمی‌شود)»).
/// [categoryId] links to a [MessageCategory]; null means «بدون دسته‌بندی».
class Draft extends Equatable {
  final String id;
  final String? title;
  final String body;
  final String? categoryId;
  final DateTime updatedAt;

  /// Pinned drafts sort above the rest, independent of [updatedAt] (DB v14).
  final bool isPinned;

  const Draft({
    required this.id,
    this.title,
    required this.body,
    this.categoryId,
    required this.updatedAt,
    this.isPinned = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'body': body,
    'category_id': categoryId,
    'updated_at': updatedAt.millisecondsSinceEpoch,
    'is_pinned': isPinned ? 1 : 0,
  };

  factory Draft.fromMap(Map<String, dynamic> map) => Draft(
    id: map['id'] as String,
    title: map['title'] as String?,
    body: map['body'] as String,
    categoryId: map['category_id'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
    isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
  );

  Draft copyWith({
    String? title,
    String? body,
    String? categoryId,
    bool clearCategory = false,
    DateTime? updatedAt,
    bool? isPinned,
  }) => Draft(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
    updatedAt: updatedAt ?? this.updatedAt,
    isPinned: isPinned ?? this.isPinned,
  );

  @override
  List<Object?> get props => [id, title, body, categoryId, updatedAt, isPinned];
}
