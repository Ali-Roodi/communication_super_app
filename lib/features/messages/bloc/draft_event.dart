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

/// Multi-select actions on the drafts grid.
class DeleteDrafts extends DraftEvent {
  final List<String> ids;
  const DeleteDrafts(this.ids);

  @override
  List<Object?> get props => [ids];
}

class PinDrafts extends DraftEvent {
  final List<String> ids;
  final bool pin;
  const PinDrafts(this.ids, {this.pin = true});

  @override
  List<Object?> get props => [ids, pin];
}

/// Files a selection under [categoryId]; null means «بدون دسته‌بندی».
class MoveDraftsToCategory extends DraftEvent {
  final List<String> ids;
  final String? categoryId;
  const MoveDraftsToCategory(this.ids, this.categoryId);

  @override
  List<Object?> get props => [ids, categoryId];
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

/// Multi-select actions on the categories list.
class DeleteCategories extends DraftEvent {
  final List<String> ids;
  const DeleteCategories(this.ids);

  @override
  List<Object?> get props => [ids];
}

class PinCategories extends DraftEvent {
  final List<String> ids;
  final bool pin;
  const PinCategories(this.ids, {this.pin = true});

  @override
  List<Object?> get props => [ids, pin];
}
