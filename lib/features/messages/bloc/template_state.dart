import 'package:equatable/equatable.dart';
import '../models/message_template_model.dart';

abstract class TemplateState extends Equatable {
  const TemplateState();

  @override
  List<Object?> get props => [];
}

class TemplateInitial extends TemplateState {
  const TemplateInitial();
}

class TemplateLoading extends TemplateState {
  const TemplateLoading();
}

class TemplatesLoaded extends TemplateState {
  final List<MessageTemplate> templates;

  const TemplatesLoaded(this.templates);

  @override
  List<Object?> get props => [templates];
}

class TemplateError extends TemplateState {
  final String message;

  const TemplateError(this.message);

  @override
  List<Object?> get props => [message];
}
