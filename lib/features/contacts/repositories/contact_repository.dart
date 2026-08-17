import 'dart:async';
import 'dart:typed_data';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import 'package:communication_super_app/core/services/device_sync_queue.dart';
import 'package:communication_super_app/core/utils/contact_name_style.dart';
import 'package:communication_super_app/core/utils/persian_alphabet.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import '../models/contact_model.dart';
import '../models/phone_match.dart';
import '../services/sim_contacts_service.dart';

class ContactRepository {
  static List<ContactModel>? _cache;

  /// In-flight device read; concurrent callers await the same future instead
  /// of busy-waiting on a polling loop.
  static Completer<void>? _loading;

  /// Bumped by every [invalidateCache] / `forceRefresh`. A read that started
  /// before the bump must NOT publish its result: saving a contact invalidates
  /// the cache while the address-book change listener already has a read in
  /// flight, and letting that pre-write snapshot land is exactly why a contact
  /// added from a call log stayed missing from the list and the search until
  /// the next restart.
  static int _generation = 0;

  /// Invalidate the cache to force a reload on next request
  void invalidateCache() {
    _cache = null;
    _generation++;
    // Drop the derived number index too. It is keyed by the identity of the
    // contact list it was built from, so a stale index would keep answering
    // [cachedByPhoneNumber] with a contact that has since been deleted or
    // renumbered until the next full read lands.
    _indexSource = null;
    _numberIndex = null;
  }

  Future<bool> _ensurePermission() async {
    return device_contacts.FlutterContacts.requestPermission();
  }

  Future<List<ContactModel>> getDeviceContacts({
    bool forceRefresh = false,
  }) async {
    if (forceRefresh) {
      _cache = null;
      _generation++;
    }
    if (_cache != null) return _cache!;

    final inFlight = _loading;
    if (inFlight != null) {
      final startedAt = _generation;
      await inFlight.future;
      // Only reuse the piggybacked read if nothing invalidated underneath it.
      if (_generation == startedAt && _cache != null) return _cache!;
      return getDeviceContacts();
    }

    final generation = _generation;
    final completer = Completer<void>();
    _loading = completer;
    try {
      final hasPermission = await _ensurePermission();
      if (!hasPermission) {
        if (_generation == generation) _cache = const <ContactModel>[];
        return const <ContactModel>[];
      }

      // Names + numbers only. Avatars are intentionally NOT loaded here:
      // holding the decoded thumbnail of every contact permanently in this
      // static cache blew the heap on large address books (OOM kills / GC
      // thrash on aggressive-memory OEMs). Each visible row and the detail
      // screen fetch their own thumbnail lazily by id — see
      // [getContactThumbnail] / LazyContactAvatar.
      // Queued: on a cold start this read races the SMS and call-log imports,
      // and three large channel payloads resident at once is what kills the
      // app on a low-memory phone (see [DeviceSyncQueue]).
      final contacts = await DeviceSyncQueue.run(
        () => device_contacts.FlutterContacts.getContacts(
          withProperties: true,
          withThumbnail: false,
          withPhoto: false,
        ),
      );

      final now = DateTime.now();
      final list = <ContactModel>[];
      for (final c in contacts) {
        final phones = c.phones
            .map((p) => p.number)
            .where((p) => p.isNotEmpty)
            .toList();
        // Contacts without a number are kept: Google Contacts lists them too
        // (their call/message actions simply grey out). Call sites that *need*
        // a number — the SMS recipient picker, the favourites picker — filter
        // on `phoneNumbers` themselves.
        // «قالب نام» is applied here, at the one place a ContactModel is built
        // from the provider, so every surface in the app — list, search, dialer
        // suggestions, call-log resolution — shows the same string. The parts
        // are kept too: the editor and the sort need them.
        final display = c.displayName.isNotEmpty ? c.displayName : 'بدون نام';
        list.add(
          ContactModel(
            id: c.id,
            name: ContactNameStyle.format(
              displayName: display,
              first: c.name.first,
              last: c.name.last,
            ),
            firstName: c.name.first,
            lastName: c.name.last,
            phoneNumber: phones.isNotEmpty ? phones.first : '',
            phoneNumbers: phones,
            email: c.emails.isNotEmpty ? c.emails.first.address : null,
            createdAt: now,
            updatedAt: now,
          ),
        );
      }
      // The SIM address book is a SEPARATE provider — see [_mergeSimContacts].
      final merged = _sorted(await _mergeSimContacts(list));

      // Stale snapshot (the address book changed while this read was running):
      // hand the caller the fresh data instead of caching what it just missed.
      if (_generation != generation) return merged;
      _cache = merged;
      return _cache!;
    } finally {
      _loading = null;
      completer.complete();
    }
  }

  /// Orders the merged address book.
  ///
  /// Three things need this and none of them come free from the provider:
  /// «مرتب‌سازی بر اساس نام خانوادگی» is not an ordering `ContactsContract` was
  /// asked for, the SIM cards' contacts are appended *after* the phone's (so
  /// they sat in a clump at the bottom of the list), and the fast-scroll index
  /// jumps to an offset computed from the section ranks — an order that
  /// disagrees with those ranks lands the jump on the wrong name.
  ///
  /// Decorate–sort–undecorate: the key folds the name and is built once per
  /// contact, not once per comparison.
  List<ContactModel> _sorted(List<ContactModel> contacts) {
    final letters = activeIndexLetters();
    final keyed = [
      for (final c in contacts)
        (key: PersianCollator.sortKey(c.sortName, letters), contact: c),
    ]..sort((a, b) => a.key.compareTo(b.key));
    return [for (final e in keyed) e.contact];
  }

  /// Appends the SIM cards' own address books to the phone's.
  ///
  /// `flutter_contacts` reads `ContactsContract`, and **SIM contacts are not
  /// in it**: the provider only carries them once the device's *default*
  /// contacts app has registered a SIM account and imported the card, which
  /// does not happen on a phone where this app is the contacts surface. That
  /// is the whole of "I put my second SIM in and its contacts never appeared"
  /// — the read was correct, it was reading the wrong provider. Google
  /// Contacts queries `content://icc/adn` directly for the same reason.
  ///
  /// A SIM row whose number the phone book already has is dropped: importing a
  /// card is the first thing most people do, and showing both copies would
  /// double every one of those contacts. The phone copy wins because it is the
  /// editable one and it carries the photo, the second number and the email.
  Future<List<ContactModel>> _mergeSimContacts(
    List<ContactModel> phoneContacts,
  ) async {
    final simContacts = await SimContactsService.read();
    if (simContacts.isEmpty) return phoneContacts;

    final known = <String>{};
    for (final c in phoneContacts) {
      for (final p in [...c.phoneNumbers, c.phoneNumber]) {
        final key = PhoneNormalizer.toThreadId(p);
        if (key.isNotEmpty) known.add(key);
      }
    }

    final merged = List<ContactModel>.of(phoneContacts);
    for (final sim in simContacts) {
      final key = PhoneNormalizer.toThreadId(sim.primaryPhone);
      // A number-less ADN record was already dropped by the service; a
      // number that normalizes to nothing (a stored service code) is kept,
      // since it cannot collide with anything.
      if (key.isNotEmpty && !known.add(key)) continue;
      merged.add(sim);
    }
    return merged;
  }

  /// Lazily fetches the thumbnail bytes for a single device contact by id.
  /// Returns null when the id is empty, the contact has no photo, or the read
  /// fails. Callers cache the result (see LazyContactAvatar).
  Future<Uint8List?> getContactThumbnail(String contactId) async {
    if (contactId.isEmpty) return null;
    // A SIM contact has no photo — an ADN record is a name and a number — and
    // its id is not a ContactsContract id, so asking would be a wasted
    // platform round-trip per visible row.
    if (contactId.startsWith('sim:')) return null;
    try {
      final c = await device_contacts.FlutterContacts.getContact(
        contactId,
        withProperties: false,
        withThumbnail: true,
        withPhoto: false,
      );
      return c?.thumbnail;
    } catch (_) {
      return null;
    }
  }

  Future<List<ContactModel>> getAllContacts({bool forceRefresh = false}) async {
    return getDeviceContacts(forceRefresh: forceRefresh);
  }

  /// Finds the device contact owning [phoneNumber], matching on the normalized
  /// national number across **all** of each contact's numbers, so `+98…` and
  /// `09…` both resolve.
  ///
  /// This used to query the local `contacts` SQLite table — which nothing
  /// writes to anymore — so it returned null for every device contact and
  /// messages lost their contact linkage. Now it reads the same device-contact
  /// cache the lists use.
  /// Memoized normalized-number → contact index, rebuilt only when the contact
  /// cache is replaced.
  ///
  /// A linear scan here normalizes every number of every contact *per lookup*,
  /// and the callers are loops: one lookup per starred message, per favourite,
  /// per incoming SMS. On a large address book that turned a screen open into
  /// millions of string ops on the main isolate.
  static List<ContactModel>? _indexSource;
  static Map<String, ContactModel>? _numberIndex;

  Future<Map<String, ContactModel>> _numberLookup() async {
    final contacts = await getDeviceContacts();
    final cached = _numberIndex;
    if (cached != null && identical(_indexSource, contacts)) return cached;

    final index = <String, ContactModel>{};
    for (final c in contacts) {
      for (final p in [...c.phoneNumbers, c.phoneNumber]) {
        final key = PhoneNormalizer.toThreadId(p);
        if (key.isNotEmpty) index.putIfAbsent(key, () => c);
      }
    }
    _indexSource = contacts;
    _numberIndex = index;
    return index;
  }

  Future<ContactModel?> getContactByPhoneNumber(String phoneNumber) async {
    final target = PhoneNormalizer.toThreadId(phoneNumber);
    if (target.isEmpty) return null;
    return (await _numberLookup())[target];
  }

  /// Non-blocking [getContactByPhoneNumber]: answers from the memoized number
  /// index when it is already built, and null when it is not.
  ///
  /// Null therefore means "unknown", not "no such contact" — use
  /// [hasNumberIndex] to tell the two apart. This exists so a list row can
  /// resolve its contact inside `build` on the common (warm) path instead of
  /// every row awaiting a future and rebuilding a frame later; see
  /// `PhoneContactAvatar`.
  static ContactModel? cachedByPhoneNumber(String phoneNumber) {
    final index = _numberIndex;
    if (index == null) return null;
    final target = PhoneNormalizer.toThreadId(phoneNumber);
    return target.isEmpty ? null : index[target];
  }

  /// Whether [cachedByPhoneNumber] can answer authoritatively.
  static bool get hasNumberIndex => _numberIndex != null;

  Future<List<ContactModel>> searchContacts(String query) async {
    return matchContacts(await getDeviceContacts(), query);
  }

  /// The one contact matcher the address-book search, the message recipient
  /// picker and anything else filtering a contact list share.
  ///
  /// A query of digits is matched as a *number* (through [SearchText.phoneContains],
  /// so `0912…` finds a contact stored as `+98912…`); anything else is matched
  /// against the name and the email with Persian folding. A mixed query is
  /// tried both ways — the user does not owe the search a category.
  ///
  /// The old version compared raw lowercased substrings, which is why a contact
  /// just saved from a call log was invisible under both its name (stored with
  /// «ي» where the user typed «ی») and its number (stored as `+98…`).
  static List<ContactModel> matchContacts(
    List<ContactModel> contacts,
    String query,
  ) {
    final trimmed = query.trim();
    if (trimmed.isEmpty) return List<ContactModel>.of(contacts);

    // Compiled once for the whole list, not once per contact — see [PhoneQuery].
    final phoneQuery = PhoneQuery(trimmed);
    // A query that is nothing but digits/punctuation is a number search; one
    // with letters is a name search. Both run when the query mixes them.
    final numeric = !phoneQuery.isEmpty;
    final textual = SearchText.fold(
      trimmed,
    ).replaceAll(_punctuationOrDigits, '').isNotEmpty;

    return contacts.where((contact) {
      if (numeric && contact.phoneNumbers.any(phoneQuery.contains)) return true;
      if (!textual) return false;
      if (SearchText.nameContains(contact.name, trimmed)) return true;
      final email = contact.email;
      return email != null && SearchText.nameContains(email, trimmed);
    }).toList();
  }

  /// Everything a *number* query is made of — what is left after stripping it
  /// decides whether the query is also worth matching against names.
  static final RegExp _punctuationOrDigits = RegExp(r'[\d\s+\-().]');

  /// Filters contacts by phone number digits (for dialer smart suggestions)
  /// Returns contacts whose phone numbers contain the given digits sequence
  List<ContactModel> filterContactsByPhoneDigits(
    List<ContactModel> contacts,
    String digits,
  ) {
    final query = PhoneQuery(digits);
    if (query.isEmpty) return [];
    return contacts
        .where((contact) => contact.phoneNumbers.any(query.contains))
        .toList();
  }

  /// Same match as [filterContactsByPhoneDigits], but resolved down to the
  /// individual numbers: a contact whose second number was typed yields that
  /// number, and a contact matching on two of its numbers yields both.
  ///
  /// This is what the dialer and the search screen render — showing the
  /// contact's first number instead would answer a search for one number with
  /// a different one.
  ///
  /// The same digits are also read as **T9**: the keys carry letters, so «۷۲۴»
  /// is «کبری» as much as it is a number, and a keypad that can only find
  /// numbers is the one thing every other dialer on the phone can do that this
  /// one could not. Number hits come first — they are the more specific reading
  /// — and a contact already listed for its number is never repeated as a T9
  /// hit.
  List<PhoneMatch> matchPhoneDigits(
    List<ContactModel> contacts,
    String digits,
  ) {
    // Every way the query may have been written, against every way the stored
    // number may have been written — `09…` has to find a contact saved as
    // `+98…` and vice versa, which a single raw substring test cannot do.
    // Compiled once for the whole address book (this runs per dialled digit).
    final query = PhoneQuery(digits);
    if (query.isEmpty) return [];

    final matches = <PhoneMatch>[];
    final byNumber = <String>{};
    for (final contact in contacts) {
      for (final phone in contact.phoneNumbers) {
        final hit = query.match(phone);
        if (hit == null) continue;
        byNumber.add(contact.id);
        matches.add(
          PhoneMatch(
            contact: contact,
            number: phone,
            digits: hit.digits,
            matchStart: hit.start,
            matchLength: hit.length,
          ),
        );
      }
    }

    final typed = SearchText.digits(digits);
    if (typed.length < SearchText.minT9Length) return matches;
    for (final contact in contacts) {
      if (byNumber.contains(contact.id)) continue;
      // A T9 row exists to be dialled, so a contact with no number is not one.
      final number = contact.primaryPhone;
      if (number.isEmpty) continue;
      final range = SearchText.t9MatchRange(contact.name, typed);
      if (range == null) continue;
      matches.add(
        PhoneMatch(
          contact: contact,
          number: number,
          digits: '',
          nameStart: range.$1,
          nameLength: range.$2 - range.$1,
        ),
      );
    }
    return matches;
  }
}
