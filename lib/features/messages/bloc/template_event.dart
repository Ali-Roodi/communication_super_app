import 'package:equatable/equatable.dart';

abstract class TemplateEvent extends Equatable {
  const TemplateEvent();

  @override
  List<Object?> get props => [];
}

class LoadTemplates extends TemplateEvent {
  const LoadTemplates();
}

/// Create ([id] null) or update ([id] set) a template.
class SaveTemplate extends TemplateEvent {
  final String? id;
  final String title;
  final String body;
  final bool useContactName;

  const SaveTemplate({
    this.id,
    required this.title,
    required this.body,
    this.useContactName = false,
  });

  @override
  List<Object?> get props => [id, title, body, useContactName];
}

class DeleteTemplates extends TemplateEvent {
  final List<String> ids;
  const DeleteTemplates(this.ids);

  @override
  List<Object?> get props => [ids];
}

class PinTemplates extends TemplateEvent {
  final List<String> ids;
  final bool pin;
  const PinTemplates(this.ids, {this.pin = true});

  @override
  List<Object?> get props => [ids, pin];
}
