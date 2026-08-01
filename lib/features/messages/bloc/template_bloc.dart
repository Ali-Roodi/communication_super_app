import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../models/message_template_model.dart';
import '../repositories/template_repository.dart';
import 'template_event.dart';
import 'template_state.dart';

/// Manages message templates («قالب‌های آماده»).
class TemplateBloc extends Bloc<TemplateEvent, TemplateState> {
  final TemplateRepository _repository;
  static const _uuid = Uuid();

  TemplateBloc(this._repository) : super(const TemplateInitial()) {
    on<LoadTemplates>(_onLoad);
    on<SaveTemplate>(_onSave);
    on<DeleteTemplates>(_onDelete);
    on<PinTemplates>(_onPin);
  }

  Future<void> _onLoad(LoadTemplates event, Emitter<TemplateState> emit) async {
    // Never blank a painted board while re-reading it (the picker re-loads on
    // open, and a save re-emits through the same path).
    if (state is! TemplatesLoaded) emit(const TemplateLoading());
    await _emitLoaded(emit);
  }

  Future<void> _emitLoaded(Emitter<TemplateState> emit) async {
    try {
      emit(TemplatesLoaded(await _repository.getTemplates()));
    } catch (e) {
      emit(TemplateError(e.toString()));
    }
  }

  Future<void> _mutate(
    Emitter<TemplateState> emit,
    Future<void> Function() action,
  ) async {
    try {
      await action();
      await _emitLoaded(emit);
    } catch (e) {
      emit(TemplateError(e.toString()));
    }
  }

  Future<void> _onSave(SaveTemplate event, Emitter<TemplateState> emit) async {
    final title = event.title.trim();
    final body = event.body.trim();
    if (body.isEmpty) return;

    // The upsert REPLACEs the row, so an edit would silently unpin the
    // template unless the existing flag is carried over (same trap as drafts).
    final existing = event.id == null
        ? null
        : await _repository.getTemplate(event.id!);

    await _mutate(
      emit,
      () => _repository.upsertTemplate(
        MessageTemplate(
          id: event.id ?? _uuid.v4(),
          title: title.isEmpty ? 'بدون عنوان' : title,
          body: body,
          useContactName: event.useContactName,
          isPinned: existing?.isPinned ?? false,
          updatedAt: DateTime.now(),
        ),
      ),
    );
  }

  Future<void> _onDelete(
    DeleteTemplates event,
    Emitter<TemplateState> emit,
  ) async => _mutate(emit, () => _repository.deleteTemplates(event.ids));

  Future<void> _onPin(PinTemplates event, Emitter<TemplateState> emit) async =>
      _mutate(emit, () => _repository.setTemplatesPinned(event.ids, event.pin));
}
