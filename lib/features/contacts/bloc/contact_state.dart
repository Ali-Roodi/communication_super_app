import 'package:equatable/equatable.dart';
import '../models/contact_model.dart';

abstract class ContactState extends Equatable {
  const ContactState();

  @override
  List<Object?> get props => [];
}

class ContactInitial extends ContactState {
  const ContactInitial();
}

class ContactLoading extends ContactState {
  const ContactLoading();
}

class ContactsLoaded extends ContactState {
  final List<ContactModel> contacts;

  const ContactsLoaded(this.contacts);

  @override
  List<Object?> get props => [contacts];
}

class ContactLoaded extends ContactState {
  final ContactModel contact;

  const ContactLoaded(this.contact);

  @override
  List<Object?> get props => [contact];
}

class ContactOperationSuccess extends ContactState {
  const ContactOperationSuccess();
}

class ContactError extends ContactState {
  final String message;

  const ContactError(this.message);

  @override
  List<Object?> get props => [message];
}

























