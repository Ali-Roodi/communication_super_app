import 'package:equatable/equatable.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';

abstract class DialerState extends Equatable {
  const DialerState();

  @override
  List<Object?> get props => [];
}

class DialerInitial extends DialerState {
  final String phoneNumber;
  final List<ContactModel> matchingContacts;
  final bool isNumberInContacts;

  const DialerInitial({
    this.phoneNumber = '',
    this.matchingContacts = const [],
    this.isNumberInContacts = false,
  });

  @override
  List<Object?> get props => [phoneNumber, matchingContacts, isNumberInContacts];

  DialerInitial copyWith({
    String? phoneNumber,
    List<ContactModel>? matchingContacts,
    bool? isNumberInContacts,
  }) {
    return DialerInitial(
      phoneNumber: phoneNumber ?? this.phoneNumber,
      matchingContacts: matchingContacts ?? this.matchingContacts,
      isNumberInContacts: isNumberInContacts ?? this.isNumberInContacts,
    );
  }
}

class DialerLoading extends DialerState {
  final String phoneNumber;

  const DialerLoading(this.phoneNumber);

  @override
  List<Object?> get props => [phoneNumber];
}

class DialerFiltered extends DialerState {
  final String phoneNumber;
  final List<ContactModel> matchingContacts;
  final bool isNumberInContacts;

  const DialerFiltered({
    required this.phoneNumber,
    required this.matchingContacts,
    required this.isNumberInContacts,
  });

  @override
  List<Object?> get props => [phoneNumber, matchingContacts, isNumberInContacts];
}

class DialerError extends DialerState {
  final String message;

  const DialerError(this.message);

  @override
  List<Object?> get props => [message];
}


















