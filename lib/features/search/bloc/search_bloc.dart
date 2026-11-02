import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../call_history/models/call_log_model.dart';
import '../../call_history/repositories/call_log_repository.dart';
import '../../messages/models/message_model.dart';
import '../../messages/repositories/message_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

/// Unified search across device contacts, recent calls and **messages**.
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  final ContactRepository _contactRepository;
  final CallLogRepository _callLogRepository;
  final MessageRepository _messageRepository;

  /// One page of «پیام‌ها» hits. A two-letter query can match half a mailbox,
  /// so the hits are read a page at a time as the list scrolls.
  static const int _kMessagePage = 40;

  /// The address book's names by thread id, for the query on screen — the
  /// next page of message hits is named from the same map.
  Map<String, String> _nameByPhone = const {};
  bool _loadingMoreMessages = false;

  /// [MessageRepository] defaults instead of being injected only so this
  /// constructor stays source-compatible with `AppBlocProviders`; it is a
  /// stateless wrapper over the `DatabaseHelper` singleton, so a local instance
  /// is the same object graph.
  SearchBloc(
    this._contactRepository,
    this._callLogRepository, [
    MessageRepository? messageRepository,
  ]) : _messageRepository = messageRepository ?? MessageRepository(),
       super(const SearchIdle()) {
    on<SearchQueryChanged>(_onQueryChanged);
    on<LoadMoreSearchMessages>(_onLoadMoreMessages);
    on<ClearSearch>((_, emit) => emit(const SearchIdle()));
  }

  Future<void> _onQueryChanged(
    SearchQueryChanged event,
    Emitter<SearchState> emit,
  ) async {
    final q = event.query.trim();
    if (q.isEmpty) {
      emit(const SearchIdle());
      return;
    }
    // The same matcher the contacts tab and the dialer use: `+98…` ≡ `0…`, and
    // «علي» finds «علی». This screen used to carry its own raw lowercase /
    // digit-substring test and so answered the same query differently.
    final phoneQuery = PhoneQuery(q);

    final contacts = await _contactRepository.getAllContacts();
    final matchedContacts = ContactRepository.matchContacts(contacts, q);

    // Build a phone → name map to enrich call-log and message rows.
    final nameByPhone = <String, String>{};
    for (final c in contacts) {
      for (final p in c.phoneNumbers) {
        nameByPhone[PhoneNormalizer.toThreadId(p)] = c.name;
      }
    }
    _nameByPhone = nameByPhone;

    // One row per number over the whole history, newest call first — not the
    // last few hundred calls, which hid anyone not called lately.
    final allLogs = await _callLogRepository.getLatestCallPerNumber();
    final seen = <String>{};
    final matchedLogs = <CallLogModel>[];
    for (final log in allLogs) {
      final norm = PhoneNormalizer.toThreadId(log.phoneNumber);
      final name = nameByPhone[norm];
      final nameHit = name != null && SearchText.nameContains(name, q);
      final phoneHit = phoneQuery.contains(log.phoneNumber);
      if (!nameHit && !phoneHit) continue;
      // De-duplicate by number — keep the most recent (logs are DESC sorted).
      if (!seen.add(norm)) continue;
      matchedLogs.add(
        name == null
            ? log
            : CallLogModel(
                id: log.id,
                contactId: log.contactId,
                contactName: name,
                phoneNumber: log.phoneNumber,
                callType: log.callType,
                duration: log.duration,
                timestamp: log.timestamp,
                subscriptionId: log.subscriptionId,
              ),
      );
    }

    // Emitted before the message search runs: contacts come from a warm cache
    // and the call log is one bounded read, while the message search is a
    // (bounded) body scan. Painting the fast sections first is the same trick
    // `MessageBloc._emitThreads` plays with cold contact names.
    final partial = SearchResults(
      query: q,
      contacts: matchedContacts,
      callLogs: matchedLogs,
    );
    emit(partial);

    final messages = await _messageRepository.searchMessages(
      q,
      limit: _kMessagePage,
    );
    if (emit.isDone) return;
    emit(
      partial.withMessages(
        _hits(messages),
        hasMore: messages.length == _kMessagePage,
      ),
    );
  }

  List<MessageSearchHit> _hits(List<MessageModel> messages) => [
    for (final m in messages)
      MessageSearchHit(
        message: m,
        contactName: _nameByPhone[PhoneNormalizer.toThreadId(m.phoneNumber)],
      ),
  ];

  Future<void> _onLoadMoreMessages(
    LoadMoreSearchMessages event,
    Emitter<SearchState> emit,
  ) async {
    final current = state;
    if (current is! SearchResults || !current.messagesHasMore) return;
    if (_loadingMoreMessages) return;
    _loadingMoreMessages = true;
    try {
      final more = await _messageRepository.searchMessages(
        current.query,
        limit: _kMessagePage,
        offset: current.messages.length,
      );
      // The query may have changed while the page was read.
      final now = state;
      if (now is! SearchResults || now.query != current.query) return;
      emit(
        now.withMessages([
          ...now.messages,
          ..._hits(more),
        ], hasMore: more.length == _kMessagePage),
      );
    } finally {
      _loadingMoreMessages = false;
    }
  }
}
