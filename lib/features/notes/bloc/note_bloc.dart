import 'package:flutter_bloc/flutter_bloc.dart';
import 'note_event.dart';
import 'note_state.dart';
import '../repositories/note_repository.dart';

class NoteBloc extends Bloc<NoteEvent, NoteState> {
  final NoteRepository _repository = NoteRepository();

  NoteBloc() : super(const NoteInitial()) {
    on<LoadNotes>(_onLoadNotes);
    on<SearchNotes>(_onSearchNotes);
    on<CreateNote>(_onCreateNote);
    on<UpdateNote>(_onUpdateNote);
    on<DeleteNote>(_onDeleteNote);
    on<GetNoteById>(_onGetNoteById);
  }

  Future<void> _onLoadNotes(
    LoadNotes event,
    Emitter<NoteState> emit,
  ) async {
    emit(const NoteLoading());
    try {
      final notes = await _repository.getAllNotes();
      emit(NotesLoaded(notes));
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }

  Future<void> _onSearchNotes(
    SearchNotes event,
    Emitter<NoteState> emit,
  ) async {
    if (event.query.isEmpty) {
      add(const LoadNotes());
      return;
    }
    emit(const NoteLoading());
    try {
      final notes = await _repository.searchNotes(event.query);
      emit(NotesLoaded(notes));
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }

  Future<void> _onCreateNote(
    CreateNote event,
    Emitter<NoteState> emit,
  ) async {
    try {
      await _repository.createNote(event.note);
      emit(const NoteOperationSuccess());
      add(const LoadNotes());
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }

  Future<void> _onUpdateNote(
    UpdateNote event,
    Emitter<NoteState> emit,
  ) async {
    try {
      await _repository.updateNote(event.note);
      emit(const NoteOperationSuccess());
      add(const LoadNotes());
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }

  Future<void> _onDeleteNote(
    DeleteNote event,
    Emitter<NoteState> emit,
  ) async {
    try {
      await _repository.deleteNote(event.id);
      emit(const NoteOperationSuccess());
      add(const LoadNotes());
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }

  Future<void> _onGetNoteById(
    GetNoteById event,
    Emitter<NoteState> emit,
  ) async {
    emit(const NoteLoading());
    try {
      final note = await _repository.getNoteById(event.id);
      if (note != null) {
        emit(NoteLoaded(note));
      } else {
        emit(const NoteError('Note not found'));
      }
    } catch (e) {
      emit(NoteError(e.toString()));
    }
  }
}

























