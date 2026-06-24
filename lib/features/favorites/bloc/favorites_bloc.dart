import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:uuid/uuid.dart';
import '../models/favorite_model.dart';
import '../repositories/favorites_repository.dart';
import 'favorites_event.dart';
import 'favorites_state.dart';

class FavoritesBloc extends Bloc<FavoritesEvent, FavoritesState> {
  final FavoritesRepository _repository;
  static const _uuid = Uuid();

  FavoritesBloc(this._repository) : super(const FavoritesInitial()) {
    on<LoadFavorites>(_onLoad);
    on<AddFavorite>(_onAdd);
    on<RemoveFavorite>(_onRemove);
  }

  Future<void> _onLoad(
    LoadFavorites event,
    Emitter<FavoritesState> emit,
  ) async {
    emit(const FavoritesLoading());
    try {
      emit(FavoritesLoaded(await _repository.getFavorites()));
    } catch (e) {
      emit(FavoritesError(e.toString()));
    }
  }

  Future<void> _onAdd(AddFavorite event, Emitter<FavoritesState> emit) async {
    try {
      final normalized = FavoriteModel.normalize(event.phoneNumber);
      if (normalized.isEmpty) return;
      await _repository.addFavorite(
        FavoriteModel(
          id: _uuid.v4(),
          phoneNumber: event.phoneNumber,
          normalized: normalized,
          name: event.name,
          contactId: event.contactId,
          createdAt: DateTime.now(),
        ),
      );
      emit(FavoritesLoaded(await _repository.getFavorites()));
    } catch (e) {
      emit(FavoritesError(e.toString()));
    }
  }

  Future<void> _onRemove(
    RemoveFavorite event,
    Emitter<FavoritesState> emit,
  ) async {
    try {
      await _repository.removeFavorite(event.normalized);
      emit(FavoritesLoaded(await _repository.getFavorites()));
    } catch (e) {
      emit(FavoritesError(e.toString()));
    }
  }
}
