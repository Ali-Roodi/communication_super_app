import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/repositories/blocked_numbers_repository.dart';

class _MockBlockedNumbersRepository extends Mock
    implements BlockedNumbersRepository {}

class _FakeBlockedNumber extends Fake implements BlockedNumberModel {}

void main() {
  setUpAll(() => registerFallbackValue(_FakeBlockedNumber()));

  late _MockBlockedNumbersRepository repo;

  setUp(() => repo = _MockBlockedNumbersRepository());

  BlockedNumbersBloc build() => BlockedNumbersBloc(repo);

  blocTest<BlockedNumbersBloc, BlockedNumbersState>(
    'LoadBlocked emits [Loading, Loaded]',
    setUp: () =>
        when(() => repo.getBlocked()).thenAnswer((_) async => const []),
    build: build,
    act: (bloc) => bloc.add(const LoadBlocked()),
    expect: () => [
      const BlockedNumbersLoading(),
      const BlockedNumbersLoaded([]),
    ],
  );

  blocTest<BlockedNumbersBloc, BlockedNumbersState>(
    'BlockNumber persists then re-emits the loaded list',
    setUp: () {
      when(
        () => repo.block(any(), report: any(named: 'report')),
      ).thenAnswer((_) async => '09121112233');
      when(() => repo.getBlocked()).thenAnswer((_) async => const []);
    },
    build: build,
    act: (bloc) => bloc.add(const BlockNumber('0912 111 2233')),
    expect: () => [const BlockedNumbersLoaded([])],
    verify: (_) =>
        verify(() => repo.block(any(), report: any(named: 'report'))).called(1),
  );

  blocTest<BlockedNumbersBloc, BlockedNumbersState>(
    'BlockNumber with no digits is a no-op',
    build: build,
    act: (bloc) => bloc.add(const BlockNumber('no-digits')),
    expect: () => const <BlockedNumbersState>[],
    verify: (_) =>
        verifyNever(() => repo.block(any(), report: any(named: 'report'))),
  );

  blocTest<BlockedNumbersBloc, BlockedNumbersState>(
    'UnblockNumber deletes then re-emits the loaded list',
    setUp: () {
      when(() => repo.unblock(any())).thenAnswer((_) async {});
      when(() => repo.getBlocked()).thenAnswer((_) async => const []);
    },
    build: build,
    act: (bloc) => bloc.add(const UnblockNumber('09121112233')),
    expect: () => [const BlockedNumbersLoaded([])],
    verify: (_) => verify(() => repo.unblock('09121112233')).called(1),
  );
}
