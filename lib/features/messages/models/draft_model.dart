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

  const Draft({
    required this.id,
    this.title,
    required this.body,
    this.categoryId,
    required this.updatedAt,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'title': title,
    'body': body,
    'category_id': categoryId,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory Draft.fromMap(Map<String, dynamic> map) => Draft(
    id: map['id'] as String,
    title: map['title'] as String?,
    body: map['body'] as String,
    categoryId: map['category_id'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
  );

  Draft copyWith({
    String? title,
    String? body,
    String? categoryId,
    bool clearCategory = false,
    DateTime? updatedAt,
  }) => Draft(
    id: id,
    title: title ?? this.title,
    body: body ?? this.body,
    categoryId: clearCategory ? null : (categoryId ?? this.categoryId),
    updatedAt: updatedAt ?? this.updatedAt,
  );

  @override
  List<Object?> get props => [id, title, body, categoryId, updatedAt];
}
