import 'package:equatable/equatable.dart';

/// A user-defined label for organising drafts (e.g. «تولد»).
///
/// [draftCount] is a derived, display-only value (not persisted) populated by
/// the repository when listing categories.
class MessageCategory extends Equatable {
  final String id;
  final String name;
  final DateTime createdAt;
  final int draftCount;

  /// Pinned categories sort above the rest, before the name ordering (DB v14).
  final bool isPinned;

  const MessageCategory({
    required this.id,
    required this.name,
    required this.createdAt,
    this.draftCount = 0,
    this.isPinned = false,
  });

  Map<String, dynamic> toMap() => {
    'id': id,
    'name': name,
    'created_at': createdAt.millisecondsSinceEpoch,
    'is_pinned': isPinned ? 1 : 0,
  };

  factory MessageCategory.fromMap(Map<String, dynamic> map) => MessageCategory(
    id: map['id'] as String,
    name: map['name'] as String,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
    draftCount: (map['draft_count'] as int?) ?? 0,
    isPinned: ((map['is_pinned'] as int?) ?? 0) == 1,
  );

  MessageCategory copyWith({String? name, int? draftCount, bool? isPinned}) =>
      MessageCategory(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        draftCount: draftCount ?? this.draftCount,
        isPinned: isPinned ?? this.isPinned,
      );

  @override
  List<Object?> get props => [id, name, createdAt, draftCount, isPinned];
}
