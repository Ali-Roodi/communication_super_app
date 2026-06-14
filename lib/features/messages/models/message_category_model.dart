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

  const MessageCategory({
    required this.id,
    required this.name,
    required this.createdAt,
    this.draftCount = 0,
  });

  Map<String, dynamic> toMap() => {
        'id': id,
        'name': name,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory MessageCategory.fromMap(Map<String, dynamic> map) => MessageCategory(
        id: map['id'] as String,
        name: map['name'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
        draftCount: (map['draft_count'] as int?) ?? 0,
      );

  MessageCategory copyWith({String? name, int? draftCount}) => MessageCategory(
        id: id,
        name: name ?? this.name,
        createdAt: createdAt,
        draftCount: draftCount ?? this.draftCount,
      );

  @override
  List<Object?> get props => [id, name, createdAt, draftCount];
}
