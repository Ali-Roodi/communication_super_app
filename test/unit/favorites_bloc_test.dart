import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_state.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/favorites/repositories/favorites_repository.dart';

class _MockFavoritesRepository extends Mock implements FavoritesRepository {}

class _FakeFavorite extends Fake implements FavoriteModel {}

FavoriteModel _fav(String id, String number) => FavoriteModel(
  id: id,
  phoneNumber: number,
  normalized: FavoriteModel.normalize(number),
  createdAt: DateTime(2026, 1, 1),
);

void main() {
  setUpAll(() => registerFallbackValue(_FakeFavorite()));

  late _MockFavoritesRepository repo;

  setUp(() => repo = _MockFavoritesRepository());

  FavoritesBloc build() => FavoritesBloc(repo);

  blocTest<FavoritesBloc, FavoritesState>(
    'LoadFavorites emits [Loading, Loaded]',
    setUp: () => when(
      () => repo.getFavorites(),
    ).thenAnswer((_) async => [_fav('1', '09120000000')]),
    build: build,
    act: (bloc) => bloc.add(const LoadFavorites()),
    expect: () => [
      const FavoritesLoading(),
      FavoritesLoaded([_fav('1', '09120000000')]),
    ],
  );

  blocTest<FavoritesBloc, FavoritesState>(
    'AddFavorite persists then re-emits the loaded list',
    setUp: () {
      when(() => repo.addFavorite(any())).thenAnswer((_) async {});
      when(
        () => repo.getFavorites(),
      ).thenAnswer((_) async => [_fav('1', '09121112233')]);
    },
    build: build,
    act: (bloc) => bloc.add(const AddFavorite(phoneNumber: '0912 111 2233')),
    expect: () => [
      FavoritesLoaded([_fav('1', '09121112233')]),
    ],
    verify: (_) {
      verify(() => repo.addFavorite(any())).called(1);
    },
  );

  blocTest<FavoritesBloc, FavoritesState>(
    'AddFavorite with an un-numbered (empty) value is a no-op',
    build: build,
    act: (bloc) => bloc.add(const AddFavorite(phoneNumber: 'no-digits-here')),
    expect: () => const <FavoritesState>[],
    verify: (_) {
      verifyNever(() => repo.addFavorite(any()));
    },
  );

  blocTest<FavoritesBloc, FavoritesState>(
    'RemoveFavorite deletes then re-emits the loaded list',
    setUp: () {
      when(() => repo.removeFavorite(any())).thenAnswer((_) async {});
      when(() => repo.getFavorites()).thenAnswer((_) async => []);
    },
    build: build,
    act: (bloc) => bloc.add(const RemoveFavorite('09120000000')),
    expect: () => [const FavoritesLoaded([])],
    verify: (_) {
      verify(() => repo.removeFavorite('09120000000')).called(1);
    },
  );
}
