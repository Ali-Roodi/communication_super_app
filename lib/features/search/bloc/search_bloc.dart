import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../call_history/models/call_log_model.dart';
import '../../call_history/repositories/call_log_repository.dart';
import '../../messages/repositories/message_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

/// Unified search across device contacts, recent calls and **messages**.
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  final ContactRepository _contactRepository;
  final CallLogRepository _callLogRepository;
  final MessageRepository _messageRepository;

  /// How many message hits the «پیام‌ها» section shows. The repository search is
  /// bounded (see `MessageRepository.searchMessages`); this bounds the list too,
  /// because a two-letter query can match half a mailbox and nobody scrolls a
  /// search result past the first screenful.
  static const int _kMessageLimit = 40;

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

    final allLogs = await _callLogRepository.getAllCallLogs(limit: 500);
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
                simSlot: log.simSlot,
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
      limit: _kMessageLimit,
    );
    if (emit.isDone) return;
    emit(
      partial.withMessages([
        for (final m in messages)
          MessageSearchHit(
            message: m,
            contactName: nameByPhone[PhoneNormalizer.toThreadId(m.phoneNumber)],
          ),
      ]),
    );
  }
}
