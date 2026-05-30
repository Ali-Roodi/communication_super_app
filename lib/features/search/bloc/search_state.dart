import 'package:equatable/equatable.dart';
import '../../contacts/models/contact_model.dart';
import '../../call_history/models/call_log_model.dart';

abstract class SearchState extends Equatable {
  const SearchState();

  @override
  List<Object?> get props => [];
}

/// No active query.
class SearchIdle extends SearchState {
  const SearchIdle();
}

class SearchResults extends SearchState {
  final String query;
  final List<ContactModel> contacts;
  final List<CallLogModel> callLogs;

  const SearchResults({
    required this.query,
    required this.contacts,
    required this.callLogs,
  });

  bool get isEmpty => contacts.isEmpty && callLogs.isEmpty;

  @override
  List<Object?> get props => [query, contacts, callLogs];
}
