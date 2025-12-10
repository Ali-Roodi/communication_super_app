import 'package:equatable/equatable.dart';
import '../models/note_model.dart';

abstract class NoteEvent extends Equatable {
  const NoteEvent();

  @override
  List<Object?> get props => [];
}

class LoadNotes extends NoteEvent {
  const LoadNotes();
}

class SearchNotes extends NoteEvent {
  final String query;

  const SearchNotes(this.query);

  @override
  List<Object?> get props => [query];
}

class CreateNote extends NoteEvent {
  final NoteModel note;

  const CreateNote(this.note);

  @override
  List<Object?> get props => [note];
}

class UpdateNote extends NoteEvent {
  final NoteModel note;

  const UpdateNote(this.note);

  @override
  List<Object?> get props => [note];
}

class DeleteNote extends NoteEvent {
  final String id;

  const DeleteNote(this.id);

  @override
  List<Object?> get props => [id];
}

class GetNoteById extends NoteEvent {
  final String id;

  const GetNoteById(this.id);

  @override
  List<Object?> get props => [id];
}







