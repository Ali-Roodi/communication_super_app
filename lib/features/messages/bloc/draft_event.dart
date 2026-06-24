import 'package:equatable/equatable.dart';

abstract class DraftEvent extends Equatable {
  const DraftEvent();

  @override
  List<Object?> get props => [];
}

/// Load drafts + categories. [categoryId] filters drafts; null with
/// [uncategorized]=false means «همه» (all drafts).
class LoadDrafts extends DraftEvent {
  final String? categoryId;
  final bool uncategorized;

  const LoadDrafts({this.categoryId, this.uncategorized = false});

  @override
  List<Object?> get props => [categoryId, uncategorized];
}

class SaveDraft extends DraftEvent {
  /// Null id = create new; non-null = update existing.
  final String? id;
  final String? title;
  final String body;
  final String? categoryId;

  const SaveDraft({this.id, this.title, required this.body, this.categoryId});

  @override
  List<Object?> get props => [id, title, body, categoryId];
}

class DeleteDraft extends DraftEvent {
  final String id;
  const DeleteDraft(this.id);

  @override
  List<Object?> get props => [id];
}

class AddCategory extends DraftEvent {
  final String name;
  const AddCategory(this.name);

  @override
  List<Object?> get props => [name];
}

class RenameCategory extends DraftEvent {
  final String id;
  final String name;
  const RenameCategory(this.id, this.name);

  @override
  List<Object?> get props => [id, name];
}

class DeleteCategory extends DraftEvent {
  final String id;
  const DeleteCategory(this.id);

  @override
  List<Object?> get props => [id];
}
