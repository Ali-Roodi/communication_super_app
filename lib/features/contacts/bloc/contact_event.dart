import 'package:equatable/equatable.dart';
import '../models/contact_model.dart';

abstract class ContactEvent extends Equatable {
  const ContactEvent();

  @override
  List<Object?> get props => [];
}

class LoadContacts extends ContactEvent {
  const LoadContacts();
}

class SearchContacts extends ContactEvent {
  final String query;

  const SearchContacts(this.query);

  @override
  List<Object?> get props => [query];
}

class CreateContact extends ContactEvent {
  final ContactModel contact;

  const CreateContact(this.contact);

  @override
  List<Object?> get props => [contact];
}

class UpdateContact extends ContactEvent {
  final ContactModel contact;

  const UpdateContact(this.contact);

  @override
  List<Object?> get props => [contact];
}

class DeleteContact extends ContactEvent {
  final String id;

  const DeleteContact(this.id);

  @override
  List<Object?> get props => [id];
}

class GetContactById extends ContactEvent {
  final String id;

  const GetContactById(this.id);

  @override
  List<Object?> get props => [id];
}













