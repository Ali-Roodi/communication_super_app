import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_state.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';

class _MockContactRepository extends Mock implements ContactRepository {}

void main() {
  late _MockContactRepository repo;

  setUp(() => repo = _MockContactRepository());

  ContactBloc build() => ContactBloc(repo);

  blocTest<ContactBloc, ContactState>(
    'LoadContacts emits [Loading, Loaded]',
    setUp: () =>
        when(() => repo.getAllContacts()).thenAnswer((_) async => const []),
    build: build,
    act: (bloc) => bloc.add(const LoadContacts()),
    expect: () => [const ContactLoading(), const ContactsLoaded([])],
  );

  blocTest<ContactBloc, ContactState>(
    'SearchContacts with a query searches the repository',
    setUp: () => when(
      () => repo.searchContacts('علی'),
    ).thenAnswer((_) async => const []),
    build: build,
    act: (bloc) => bloc.add(const SearchContacts('علی')),
    expect: () => [const ContactLoading(), const ContactsLoaded([])],
    verify: (_) => verify(() => repo.searchContacts('علی')).called(1),
  );

  blocTest<ContactBloc, ContactState>(
    'SearchContacts with an empty query falls back to loading all contacts',
    setUp: () =>
        when(() => repo.getAllContacts()).thenAnswer((_) async => const []),
    build: build,
    act: (bloc) => bloc.add(const SearchContacts('')),
    expect: () => [const ContactLoading(), const ContactsLoaded([])],
    verify: (_) {
      verify(() => repo.getAllContacts()).called(1);
      verifyNever(() => repo.searchContacts(any()));
    },
  );

  blocTest<ContactBloc, ContactState>(
    'DeleteContact emits success then the refreshed list',
    setUp: () {
      when(() => repo.deleteContact('id-1')).thenAnswer((_) async {});
      when(() => repo.getAllContacts()).thenAnswer((_) async => const []);
    },
    build: build,
    act: (bloc) => bloc.add(const DeleteContact('id-1')),
    expect: () => [const ContactOperationSuccess(), const ContactsLoaded([])],
    verify: (_) {
      verify(() => repo.deleteContact('id-1')).called(1);
      verify(() => repo.invalidateCache()).called(1);
    },
  );
}
