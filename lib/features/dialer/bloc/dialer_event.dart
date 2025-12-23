import 'package:equatable/equatable.dart';

abstract class DialerEvent extends Equatable {
  const DialerEvent();

  @override
  List<Object?> get props => [];
}

class DialerNumberPressed extends DialerEvent {
  final String number;

  const DialerNumberPressed(this.number);

  @override
  List<Object?> get props => [number];
}

class DialerNumberCleared extends DialerEvent {
  const DialerNumberCleared();
}

class DialerNumberDeleted extends DialerEvent {
  const DialerNumberDeleted();
}

class DialerLoadContacts extends DialerEvent {
  const DialerLoadContacts();
}

class DialerFilterContacts extends DialerEvent {
  final String query;

  const DialerFilterContacts(this.query);

  @override
  List<Object?> get props => [query];
}



