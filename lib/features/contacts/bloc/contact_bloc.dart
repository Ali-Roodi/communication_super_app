import 'package:flutter_bloc/flutter_bloc.dart';
import 'contact_event.dart';
import 'contact_state.dart';
import '../repositories/contact_repository.dart';

class ContactBloc extends Bloc<ContactEvent, ContactState> {
  final ContactRepository _repository;

  ContactBloc(this._repository) : super(const ContactInitial()) {
    on<LoadContacts>(_onLoadContacts);
    on<RefreshContacts>(_onRefreshContacts);
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

  /// Reload from the device, bypassing the cache. Does not emit a loading state
  /// so the visible list doesn't flicker while it refreshes in place.
  Future<void> _onRefreshContacts(
    RefreshContacts event,
    Emitter<ContactState> emit,
  ) async {
    try {
      final contacts = await _repository.getAllContacts(forceRefresh: true);
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
      // Invalidate cache to force reload on next request
      _repository.invalidateCache();
      emit(const ContactOperationSuccess());
      // Reload contacts to show the new one
      final contacts = await _repository.getAllContacts();
      emit(ContactsLoaded(contacts));
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
      // Invalidate cache to force reload on next request
      _repository.invalidateCache();
      emit(const ContactOperationSuccess());
      // Reload contacts to show the updated one
      final contacts = await _repository.getAllContacts();
      emit(ContactsLoaded(contacts));
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
      // Invalidate cache to force reload on next request
      _repository.invalidateCache();
      emit(const ContactOperationSuccess());
      // Reload contacts to show the changes
      final contacts = await _repository.getAllContacts();
      emit(ContactsLoaded(contacts));
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
