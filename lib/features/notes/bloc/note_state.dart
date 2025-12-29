import 'package:equatable/equatable.dart';
import '../models/note_model.dart';

abstract class NoteState extends Equatable {
  const NoteState();

  @override
  List<Object?> get props => [];
}

class NoteInitial extends NoteState {
  const NoteInitial();
}

class NoteLoading extends NoteState {
  const NoteLoading();
}

class NotesLoaded extends NoteState {
  final List<NoteModel> notes;

  const NotesLoaded(this.notes);

  @override
  List<Object?> get props => [notes];
}

class NoteLoaded extends NoteState {
  final NoteModel note;

  const NoteLoaded(this.note);

  @override
  List<Object?> get props => [note];
}

class NoteOperationSuccess extends NoteState {
  const NoteOperationSuccess();
}

class NoteError extends NoteState {
  final String message;

  const NoteError(this.message);

  @override
  List<Object?> get props => [message];
}




















