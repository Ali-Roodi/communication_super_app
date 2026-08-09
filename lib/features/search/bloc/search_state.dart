import 'package:equatable/equatable.dart';
import '../../contacts/models/contact_model.dart';
import '../../call_history/models/call_log_model.dart';
import '../../messages/models/message_model.dart';

abstract class SearchState extends Equatable {
  const SearchState();

  @override
  List<Object?> get props => [];
}

/// No active query.
class SearchIdle extends SearchState {
  const SearchIdle();
}

/// One «پیام‌ها» hit: the message plus the name its number resolves to.
///
/// The name is resolved in the bloc, not in the row: a list row cannot await the
/// address book, and every row of a thread would resolve the same number again.
class MessageSearchHit extends Equatable {
  const MessageSearchHit({required this.message, this.contactName});

  final MessageModel message;
  final String? contactName;

  @override
  List<Object?> get props => [message, contactName];
}

class SearchResults extends SearchState {
  final String query;
  final List<ContactModel> contacts;
  final List<CallLogModel> callLogs;
  final List<MessageSearchHit> messages;

  /// False while the (bounded, but slowest) message search is still running.
  ///
  /// The bloc emits contacts and calls first and the messages a moment later —
  /// holding the whole screen back for the message scan would make the sections
  /// that answer instantly feel as slow as the one that does not.
  final bool messagesReady;

  const SearchResults({
    required this.query,
    required this.contacts,
    required this.callLogs,
    this.messages = const [],
    this.messagesReady = false,
  });

  bool get isEmpty => contacts.isEmpty && callLogs.isEmpty && messages.isEmpty;

  SearchResults withMessages(List<MessageSearchHit> messages) => SearchResults(
    query: query,
    contacts: contacts,
    callLogs: callLogs,
    messages: messages,
    messagesReady: true,
  );

  @override
  List<Object?> get props => [
    query,
    contacts,
    callLogs,
    messages,
    messagesReady,
  ];
}
