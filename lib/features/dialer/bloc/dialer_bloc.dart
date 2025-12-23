import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'dialer_event.dart';
import 'dialer_state.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../contacts/models/contact_model.dart';

class DialerBloc extends Bloc<DialerEvent, DialerState> {
  final ContactRepository _contactRepository;
  Timer? _debounceTimer;
  List<ContactModel> _allContacts = [];

  DialerBloc(this._contactRepository) : super(const DialerInitial()) {
    on<DialerLoadContacts>(_onLoadContacts);
    on<DialerNumberPressed>(_onNumberPressed);
    on<DialerNumberCleared>(_onNumberCleared);
    on<DialerNumberDeleted>(_onNumberDeleted);
    on<DialerFilterContacts>(_onFilterContacts);

    // Load all contacts on initialization
    add(const DialerLoadContacts());
  }

  Future<void> _onLoadContacts(
    DialerLoadContacts event,
    Emitter<DialerState> emit,
  ) async {
    try {
      _allContacts = await _contactRepository.getAllContacts();
      if (state is DialerInitial) {
        emit((state as DialerInitial).copyWith());
      }
    } catch (e) {
      emit(DialerError(e.toString()));
    }
  }

  void _onNumberPressed(
    DialerNumberPressed event,
    Emitter<DialerState> emit,
  ) {
    final currentState = state;
    String newPhoneNumber = '';
    
    if (currentState is DialerInitial) {
      newPhoneNumber = currentState.phoneNumber + event.number;
    } else if (currentState is DialerFiltered) {
      newPhoneNumber = currentState.phoneNumber + event.number;
    } else if (currentState is DialerLoading) {
      newPhoneNumber = currentState.phoneNumber + event.number;
    }

    // Cancel previous debounce timer
    _debounceTimer?.cancel();

    // Debounce the filtering
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      add(DialerFilterContacts(newPhoneNumber));
    });

    // Immediately update the phone number
    emit(DialerLoading(newPhoneNumber));
  }

  void _onNumberCleared(
    DialerNumberCleared event,
    Emitter<DialerState> emit,
  ) {
    _debounceTimer?.cancel();
    emit(const DialerInitial());
  }

  void _onNumberDeleted(
    DialerNumberDeleted event,
    Emitter<DialerState> emit,
  ) {
    final currentState = state;
    String newPhoneNumber = '';
    
    if (currentState is DialerInitial) {
      newPhoneNumber = currentState.phoneNumber;
    } else if (currentState is DialerFiltered) {
      newPhoneNumber = currentState.phoneNumber;
    } else if (currentState is DialerLoading) {
      newPhoneNumber = currentState.phoneNumber;
    }

    if (newPhoneNumber.isNotEmpty) {
      newPhoneNumber = newPhoneNumber.substring(0, newPhoneNumber.length - 1);
    }

    // Cancel previous debounce timer
    _debounceTimer?.cancel();

    if (newPhoneNumber.isEmpty) {
      emit(const DialerInitial());
    } else {
      // Debounce the filtering
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        add(DialerFilterContacts(newPhoneNumber));
      });
      emit(DialerLoading(newPhoneNumber));
    }
  }

  Future<void> _onFilterContacts(
    DialerFilterContacts event,
    Emitter<DialerState> emit,
  ) async {
    if (event.query.isEmpty) {
      emit(const DialerInitial());
      return;
    }

    try {
      // Filter contacts by phone number digits
      final matchingContacts = _contactRepository.filterContactsByPhoneDigits(
        _allContacts,
        event.query,
      );

      // Check if the exact number exists in contacts
      final isNumberInContacts = matchingContacts.any(
        (contact) => contact.phoneNumbers.any(
          (phone) => _normalizePhoneNumber(phone) == _normalizePhoneNumber(event.query),
        ),
      );

      emit(DialerFiltered(
        phoneNumber: event.query,
        matchingContacts: matchingContacts,
        isNumberInContacts: isNumberInContacts,
      ));
    } catch (e) {
      emit(DialerError(e.toString()));
    }
  }

  String _normalizePhoneNumber(String phone) {
    // Remove all non-digit characters for comparison
    return phone.replaceAll(RegExp(r'[^\d]'), '');
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    return super.close();
  }
}



