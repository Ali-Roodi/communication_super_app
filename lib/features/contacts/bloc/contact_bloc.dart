import 'dart:async';

import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'contact_event.dart';
import 'contact_state.dart';
import '../repositories/contact_repository.dart';

class ContactBloc extends Bloc<ContactEvent, ContactState> {
  final ContactRepository _repository;

  /// A SIM being inserted or removed changes the address book, because the
  /// card's own contacts are merged into it (see
  /// `ContactRepository._mergeSimContacts`). Without this the new SIM's
  /// contacts stayed invisible until the next cold start — half of the
  /// reported bug; the other half was never reading the ICC provider at all.
  StreamSubscription<List<SimCard>>? _simSub;

  ContactBloc(this._repository) : super(const ContactInitial()) {
    on<LoadContacts>(_onLoadContacts);
    on<RefreshContacts>(_onRefreshContacts);
    on<SearchContacts>(_onSearchContacts);

    _simSub = SimService.instance.onChanged.listen((_) {
      add(const RefreshContacts());
    });
  }

  @override
  Future<void> close() {
    _simSub?.cancel();
    return super.close();
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

}
