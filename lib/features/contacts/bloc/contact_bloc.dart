import 'package:flutter_bloc/flutter_bloc.dart';
import 'contact_event.dart';
import 'contact_state.dart';
import '../repositories/contact_repository.dart';

class ContactBloc extends Bloc<ContactEvent, ContactState> {
  final ContactRepository _repository;

  ContactBloc(this._repository) : super(const ContactInitial()) {
    on<LoadContacts>(_onLoadContacts);
    on<SearchContacts>(_onSearchContacts);
    on<CreateContact>(_onCreateContact);
    on<UpdateContact>(_onUpdateContact);
    on<DeleteContact>(_onDeleteContact);
    on<GetContactById>(_onGetContactById);
  }

  Future<void> _onLoadContacts(
    LoadContacts event,
    Emitter<ContactState> emit,
  ) async {
    emit(const ContactLoading());
    try {
      final contacts = await _repository.getAllContacts();
      emit(ContactsLoaded(contacts));
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }

  Future<void> _onSearchContacts(
    SearchContacts event,
    Emitter<ContactState> emit,
  ) async {
    if (event.query.isEmpty) {
      add(const LoadContacts());
      return;
    }
    emit(const ContactLoading());
    try {
      final contacts = await _repository.searchContacts(event.query);
      emit(ContactsLoaded(contacts));
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }

  Future<void> _onCreateContact(
    CreateContact event,
    Emitter<ContactState> emit,
  ) async {
    try {
      await _repository.createContact(event.contact);
      emit(const ContactOperationSuccess());
      add(const LoadContacts());
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }

  Future<void> _onUpdateContact(
    UpdateContact event,
    Emitter<ContactState> emit,
  ) async {
    try {
      await _repository.updateContact(event.contact);
      emit(const ContactOperationSuccess());
      add(const LoadContacts());
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }

  Future<void> _onDeleteContact(
    DeleteContact event,
    Emitter<ContactState> emit,
  ) async {
    try {
      await _repository.deleteContact(event.id);
      emit(const ContactOperationSuccess());
      add(const LoadContacts());
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }

  Future<void> _onGetContactById(
    GetContactById event,
    Emitter<ContactState> emit,
  ) async {
    emit(const ContactLoading());
    try {
      final contact = await _repository.getContactById(event.id);
      if (contact != null) {
        emit(ContactLoaded(contact));
      } else {
        emit(const ContactError('Contact not found'));
      }
    } catch (e) {
      emit(ContactError(e.toString()));
    }
  }
}









