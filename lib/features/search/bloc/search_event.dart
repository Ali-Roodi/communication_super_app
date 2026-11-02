import 'package:equatable/equatable.dart';

abstract class SearchEvent extends Equatable {
  const SearchEvent();

  @override
  List<Object?> get props => [];
}

class SearchQueryChanged extends SearchEvent {
  final String query;
  const SearchQueryChanged(this.query);

  @override
  List<Object?> get props => [query];
}

class ClearSearch extends SearchEvent {
  const ClearSearch();
}

/// The next page of «پیام‌ها» hits for the query on screen.
class LoadMoreSearchMessages extends SearchEvent {
  const LoadMoreSearchMessages();
}
