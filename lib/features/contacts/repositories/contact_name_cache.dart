import 'package:sqflite/sqflite.dart';

import '../../../core/constants/app_constants.dart';
import '../../../core/database/database_helper.dart';
import '../../../core/utils/phone_normalizer.dart';
import '../models/contact_model.dart';

/// One remembered address-book entry: the name a number resolved to last time,
/// and the contact id its photo can be loaded by.
class CachedContactName {
  final String name;
  final String? contactId;

  const CachedContactName(this.name, this.contactId);

  @override
  bool operator ==(Object other) =>
      other is CachedContactName &&
      other.name == name &&
      other.contactId == contactId;

  @override
  int get hashCode => Object.hash(name, contactId);
}

/// The address book as it was last read, kept in SQLite so the *first* frame
/// after a launch can already carry names.
///
/// Why this exists: the device address book lives on the other side of a
/// platform channel, and reading it whole is slow enough to see. Both «پیام‌ها»
/// and «اخیر» therefore painted their rows from SQLite immediately — as bare
/// numbers — and dropped the names in as a second emit a beat later. On a phone
/// where nothing about the address book had changed since the last launch that
/// flicker was pure loss: the answer was already known, it just was not written
/// down anywhere.
///
/// Three rules keep it honest:
///
/// * It is a **cache, never a source of truth.** Every consumer still runs the
///   real read and re-emits; when the answers agree the second emit is equal to
///   the first and the state classes being Equatable means nothing repaints.
/// * It is written **only** from a completed device read
///   (`ContactRepository.getDeviceContacts`), so it can never drift into
///   holding a name the address book does not.
/// * A number that has left the address book leaves this table with it. The
///   write replaces the whole set inside one transaction rather than upserting,
///   which is what lets a *deleted* contact's name disappear — an upsert-only
///   cache would keep naming a person the user removed.
class ContactNameCache {
  ContactNameCache._();

  static final DatabaseHelper _dbHelper = DatabaseHelper.instance;

  /// The last map read from — or written to — the table, so repeat reads are
  /// free and an unchanged address book costs no write.
  static Map<String, CachedContactName>? _memo;

  /// Last-7-digits → the one remembered entry with that tail, null where two
  /// different contacts share it. Derived from [_memo], never stored: it is the
  /// same trailing-digit fallback `ContactRepository` and `CallLogService` use,
  /// so the *first* paint agrees with the second instead of showing a number
  /// that the authoritative pass a beat later replaces with a name.
  static Map<String, CachedContactName?>? _tailMemo;

  /// The remembered index, empty on a first launch (and on any failure — a
  /// cache that cannot be read must degrade to "no names yet", never throw
  /// into the middle of a paint).
  static Future<Map<String, CachedContactName>> read() async {
    final memo = _memo;
    if (memo != null) return memo;
    try {
      final db = await _dbHelper.database;
      final rows = await db.query(
        AppConstants.contactNameCacheTable,
        columns: ['normalized', 'name', 'contact_id'],
      );
      final map = <String, CachedContactName>{
        for (final row in rows)
          row['normalized'] as String: CachedContactName(
            row['name'] as String,
            row['contact_id'] as String?,
          ),
      };
      return _memo = _withTails(map);
    } catch (_) {
      return _memo = _withTails(const {});
    }
  }

  /// Rebuilds [_tailMemo] alongside a new [_memo] and hands the map back, so
  /// the two can never be set apart from one another.
  static Map<String, CachedContactName> _withTails(
    Map<String, CachedContactName> map,
  ) {
    final tails = <String, CachedContactName?>{};
    map.forEach((normalized, entry) {
      final tail = PhoneNormalizer.toTailKey(normalized);
      if (tail.isEmpty) return;
      tails.update(
        tail,
        (existing) => existing == entry ? existing : null,
        ifAbsent: () => entry,
      );
    });
    _tailMemo = tails;
    return map;
  }

  /// The remembered name for [phone]: the exact key, else the unambiguous
  /// trailing-digits match. Null means "not remembered".
  static CachedContactName? lookup(String phone) {
    final memo = _memo;
    if (memo == null) return null;
    final key = PhoneNormalizer.toThreadId(phone);
    if (key.isEmpty) return null;
    final exact = memo[key];
    if (exact != null) return exact;
    final tail = PhoneNormalizer.toTailKey(phone);
    return tail.isEmpty ? null : _tailMemo?[tail];
  }

  /// Answers from the already-read map, or null when it has not been read yet.
  ///
  /// Lets a `build` take the fast path without awaiting; null means "unknown",
  /// not "no such contact".
  static Map<String, CachedContactName>? get cached => _memo;

  /// Rewrites the table to match [contacts].
  ///
  /// Cheap in the case that matters: the map is built and compared first, and an
  /// address book that has not changed since the last write does not touch the
  /// database at all.
  ///
  /// SIM (ADN) records are indexed by name but never by id — an ADN row has no
  /// `ContactsContract` id, so handing one to the avatar loader is a lookup that
  /// can only fail.
  static Future<void> write(List<ContactModel> contacts) async {
    final next = <String, CachedContactName>{};
    for (final contact in contacts) {
      if (contact.name.isEmpty) continue;
      final entry = CachedContactName(
        contact.name,
        contact.isSimContact ? null : contact.id,
      );
      for (final phone in [...contact.phoneNumbers, contact.phoneNumber]) {
        final key = PhoneNormalizer.toThreadId(phone);
        if (key.isEmpty) continue;
        next.putIfAbsent(key, () => entry);
      }
    }
    if (_mapEquals(_memo, next)) return;
    _memo = _withTails(next);
    try {
      final db = await _dbHelper.database;
      await db.transaction((txn) async {
        await txn.delete(AppConstants.contactNameCacheTable);
        final batch = txn.batch();
        next.forEach((normalized, value) {
          batch.insert(AppConstants.contactNameCacheTable, {
            'normalized': normalized,
            'name': value.name,
            'contact_id': value.contactId,
          }, conflictAlgorithm: ConflictAlgorithm.replace);
        });
        await batch.commit(noResult: true);
      });
    } catch (_) {
      // Persisting is an optimization; failing it must not fail the read that
      // produced the contacts. The in-memory copy still serves this session.
    }
  }

  static bool _mapEquals(
    Map<String, CachedContactName>? a,
    Map<String, CachedContactName> b,
  ) {
    if (a == null || a.length != b.length) return false;
    for (final entry in b.entries) {
      if (a[entry.key] != entry.value) return false;
    }
    return true;
  }

  /// Test seam: forget what this process has read.
  static void resetForTest() {
    _memo = null;
    _tailMemo = null;
  }
}
