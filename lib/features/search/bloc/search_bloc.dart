import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../call_history/models/call_log_model.dart';
import '../../call_history/repositories/call_log_repository.dart';
import 'search_event.dart';
import 'search_state.dart';

/// Unified search across device contacts and recent calls.
class SearchBloc extends Bloc<SearchEvent, SearchState> {
  final ContactRepository _contactRepository;
  final CallLogRepository _callLogRepository;

  SearchBloc(this._contactRepository, this._callLogRepository)
    : super(const SearchIdle()) {
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

    // Build a phone → name map to enrich call-log rows.
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

    emit(
      SearchResults(query: q, contacts: matchedContacts, callLogs: matchedLogs),
    );
  }
}
