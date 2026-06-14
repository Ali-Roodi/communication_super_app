import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../models/draft_model.dart';
import '../models/message_category_model.dart';
import '../repositories/draft_repository.dart';
import 'draft_event.dart';
import 'draft_state.dart';

/// Manages drafts (پیش‌نویس‌ها) and their categories (دسته‌بندی‌ها).
class DraftBloc extends Bloc<DraftEvent, DraftState> {
  final DraftRepository _repository;
  static const _uuid = Uuid();

  // Remember the active filter so mutations re-load the same view.
  String? _filterCategoryId;
  bool _filterUncategorized = false;

  DraftBloc(this._repository) : super(const DraftInitial()) {
    on<LoadDrafts>(_onLoad);
    on<SaveDraft>(_onSave);
    on<DeleteDraft>(_onDelete);
    on<AddCategory>(_onAddCategory);
    on<RenameCategory>(_onRenameCategory);
    on<DeleteCategory>(_onDeleteCategory);
  }

  Future<void> _onLoad(LoadDrafts event, Emitter<DraftState> emit) async {
    _filterCategoryId = event.categoryId;
    _filterUncategorized = event.uncategorized;
    if (state is! DraftsLoaded) emit(const DraftLoading());
    await _emitLoaded(emit);
  }

  Future<void> _emitLoaded(Emitter<DraftState> emit) async {
    try {
      final drafts = await _repository.getDrafts(
        categoryId: _filterCategoryId,
        uncategorized: _filterUncategorized,
      );
      final categories = await _repository.getCategories();
      final counts = await _repository.getDraftCounts();
      emit(DraftsLoaded(
        drafts: drafts,
        categories: categories,
        totalCount: counts.total,
        uncategorizedCount: counts.uncategorized,
        filterCategoryId: _filterCategoryId,
        filterUncategorized: _filterUncategorized,
      ));
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }

  Future<void> _onSave(SaveDraft event, Emitter<DraftState> emit) async {
    try {
      if (event.body.trim().isEmpty) return;
      await _repository.upsertDraft(Draft(
        id: event.id ?? _uuid.v4(),
        title: (event.title?.trim().isEmpty ?? true) ? null : event.title!.trim(),
        body: event.body.trim(),
        categoryId: event.categoryId,
        updatedAt: DateTime.now(),
      ));
      await _emitLoaded(emit);
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }

  Future<void> _onDelete(DeleteDraft event, Emitter<DraftState> emit) async {
    try {
      await _repository.deleteDraft(event.id);
      await _emitLoaded(emit);
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }

  Future<void> _onAddCategory(
      AddCategory event, Emitter<DraftState> emit) async {
    try {
      final name = event.name.trim();
      if (name.isEmpty) return;
      await _repository.addCategory(MessageCategory(
        id: _uuid.v4(),
        name: name,
        createdAt: DateTime.now(),
      ));
      await _emitLoaded(emit);
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }

  Future<void> _onRenameCategory(
      RenameCategory event, Emitter<DraftState> emit) async {
    try {
      final name = event.name.trim();
      if (name.isEmpty) return;
      await _repository.renameCategory(event.id, name);
      await _emitLoaded(emit);
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }

  Future<void> _onDeleteCategory(
      DeleteCategory event, Emitter<DraftState> emit) async {
    try {
      // If we were filtering by the deleted category, fall back to «همه».
      if (_filterCategoryId == event.id) {
        _filterCategoryId = null;
        _filterUncategorized = false;
      }
      await _repository.deleteCategory(event.id);
      await _emitLoaded(emit);
    } catch (e) {
      emit(DraftError(e.toString()));
    }
  }
}
