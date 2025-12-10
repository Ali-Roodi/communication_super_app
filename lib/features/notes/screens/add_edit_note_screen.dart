import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../bloc/note_bloc.dart';
import '../bloc/note_event.dart';
import '../bloc/note_state.dart';
import '../models/note_model.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

class AddEditNoteScreen extends StatefulWidget {
  final String? noteId;

  const AddEditNoteScreen({
    super.key,
    this.noteId,
  });

  @override
  State<AddEditNoteScreen> createState() => _AddEditNoteScreenState();
}

class _AddEditNoteScreenState extends State<AddEditNoteScreen> {
  final _formKey = GlobalKey<FormState>();
  final _titleController = TextEditingController();
  final _contentController = TextEditingController();
  NoteModel? _originalNote;

  @override
  void initState() {
    super.initState();
    if (widget.noteId != null) {
      context.read<NoteBloc>().add(GetNoteById(widget.noteId!));
    }
  }

  @override
  void dispose() {
    _titleController.dispose();
    _contentController.dispose();
    super.dispose();
  }

  void _saveNote() {
    if (_formKey.currentState!.validate()) {
      final now = DateTime.now();
      final note = NoteModel(
        id: widget.noteId ?? const Uuid().v4(),
        title: _titleController.text.trim(),
        content: _contentController.text.trim(),
        createdAt: _originalNote?.createdAt ?? now,
        updatedAt: now,
      );

      if (widget.noteId != null) {
        context.read<NoteBloc>().add(UpdateNote(note));
      } else {
        context.read<NoteBloc>().add(CreateNote(note));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<NoteBloc, NoteState>(
      listener: (context, state) {
        if (state is NoteLoaded && widget.noteId != null) {
          _originalNote = state.note;
          _titleController.text = state.note.title;
          _contentController.text = state.note.content;
        }

        if (state is NoteOperationSuccess) {
          Navigator.of(context).pop();
        }

        if (state is NoteError) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text(state.message)),
          );
        }
      },
      child: Scaffold(
        appBar: RtlAppBar(
          title: widget.noteId != null ? 'Edit Note' : 'New Note',
          actions: [
            TextButton(
              onPressed: _saveNote,
              child: const Text('Save'),
            ),
          ],
        ),
        body: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              TextFormField(
                controller: _titleController,
                decoration: const InputDecoration(
                  labelText: 'Title',
                  border: OutlineInputBorder(),
                ),
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter a title';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),
              TextFormField(
                controller: _contentController,
                decoration: const InputDecoration(
                  labelText: 'Content',
                  border: OutlineInputBorder(),
                  alignLabelWithHint: true,
                ),
                maxLines: 20,
                validator: (value) {
                  if (value == null || value.trim().isEmpty) {
                    return 'Please enter content';
                  }
                  return null;
                },
              ),
            ],
          ),
        ),
      ),
    );
  }
}


