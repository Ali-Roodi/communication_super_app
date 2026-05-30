import 'package:equatable/equatable.dart';

abstract class FavoritesEvent extends Equatable {
  const FavoritesEvent();

  @override
  List<Object?> get props => [];
}

class LoadFavorites extends FavoritesEvent {
  const LoadFavorites();
}

class AddFavorite extends FavoritesEvent {
  final String phoneNumber;
  final String? name;
  final String? contactId;

  const AddFavorite({
    required this.phoneNumber,
    this.name,
    this.contactId,
  });

  @override
  List<Object?> get props => [phoneNumber, name, contactId];
}

class RemoveFavorite extends FavoritesEvent {
  final String normalized;

  const RemoveFavorite(this.normalized);

  @override
  List<Object?> get props => [normalized];
}
