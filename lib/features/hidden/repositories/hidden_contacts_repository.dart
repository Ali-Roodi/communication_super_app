import 'package:equatable/equatable.dart';
// SQLCipher's API types — the hidden phonebook lives only in `secure.db`.
import 'package:sqflite_sqlcipher/sqflite.dart' as cipher;

import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart'
    show KeyBankLockedException;
import 'package:communication_super_app/features/secure/repositories/secure_store.dart';

class HiddenNumber extends Equatable {
  const HiddenNumber({required this.phone, this.label});

  /// Whether an SMS can go to it: a mobile (`09…`), not a landline.
  bool get textable => phone.startsWith('09');

  /// Canonical (`SmsCryptoService.canonicalPhone`), like every number in
  /// `secure.db`.
  final String phone;
  final String? label;

  @override
  List<Object?> get props => [phone, label];
}

/// A contact of «دفترچه مخفی». Never in the system address book: other apps
/// that read contacts cannot see it (matrix row 35).
class HiddenContact extends Equatable {
  const HiddenContact({
    required this.id,
    required this.name,
    required this.numbers,
    this.note,
    this.createdAt = 0,
    this.updatedAt = 0,
  });

  final String id;
  final String name;
  final List<HiddenNumber> numbers;
  final String? note;
  final int createdAt;
  final int updatedAt;

  String? get primaryPhone => numbers.isEmpty ? null : numbers.first.phone;

  HiddenContact copyWith({
    String? name,
    List<HiddenNumber>? numbers,
    String? note,
  }) => HiddenContact(
    id: id,
    name: name ?? this.name,
    numbers: numbers ?? this.numbers,
    note: note ?? this.note,
    createdAt: createdAt,
    updatedAt: updatedAt,
  );

  @override
  List<Object?> get props => [id, name, numbers, note, createdAt, updatedAt];
}

/// One call with a hidden number, moved out of the system call log.
class HiddenCall extends Equatable {
  const HiddenCall({
    required this.id,
    required this.phone,
    required this.callType,
    required this.timestamp,
    this.duration,
    this.account,
  });

  final int id;
  final String phone;

  /// The raw `CallLog.Calls.TYPE` (1 incoming, 2 outgoing, 3 missed,
  /// 5 rejected, 6 blocked, …).
  final int callType;
  final int timestamp;
  final int? duration;

  /// `CallLog.Calls.PHONE_ACCOUNT_ID` — which SIM, where known.
  final String? account;

  @override
  List<Object?> get props => [
    id,
    phone,
    callType,
    timestamp,
    duration,
    account,
  ];
}

/// A call as a sealed record carries it, before it has a row id.
class HiddenCallRecord {
  const HiddenCallRecord({
    required this.phone,
    required this.callType,
    required this.timestamp,
    this.duration,
    this.account,
  });
  final String phone;
  final int callType;
  final int timestamp;
  final int? duration;
  final String? account;
}

/// «دفترچه مخفی» and its calls, in `secure.db` (tables made by
/// [SecureStore]). Works only while the secure section is open; otherwise
/// every call throws [KeyBankLockedException].
class HiddenContactsRepository {
  HiddenContactsRepository({cipher.Database? Function()? database})
    : _database = database ?? (() => SecureStore.instance.database);

  final cipher.Database? Function() _database;

  cipher.Database get _db =>
      _database() ?? (throw const KeyBankLockedException());

  // ── Contacts ─────────────────────────────────────────────────────────────

  Future<List<HiddenContact>> contacts() async {
    final rows = await _db.query('hc_contacts', orderBy: 'name COLLATE NOCASE');
    final numbers = await _numbersByContact();
    return [for (final r in rows) _contact(r, numbers[r['id']] ?? const [])];
  }

  Future<HiddenContact?> contact(String id) async {
    final rows = await _db.query(
      'hc_contacts',
      where: 'id = ?',
      whereArgs: [id],
    );
    if (rows.isEmpty) return null;
    return _contact(rows.first, (await _numbersByContact(id))[id] ?? const []);
  }

  /// Creates or replaces [contact] with exactly its numbers, in order.
  Future<void> save(HiddenContact contact, int now) =>
      _db.transaction((txn) async {
        final existing = await txn.query(
          'hc_contacts',
          columns: ['created_at'],
          where: 'id = ?',
          whereArgs: [contact.id],
        );
        await txn.insert('hc_contacts', {
          'id': contact.id,
          'name': contact.name,
          'note': contact.note,
          'created_at': existing.isEmpty
              ? now
              : existing.first['created_at'] as int,
          'updated_at': now,
        }, conflictAlgorithm: cipher.ConflictAlgorithm.replace);
        await txn.delete(
          'hc_numbers',
          where: 'contact_id = ?',
          whereArgs: [contact.id],
        );
        var position = 0;
        for (final n in contact.numbers) {
          await txn.insert('hc_numbers', {
            'contact_id': contact.id,
            'phone': n.phone,
            'label': n.label,
            'position': position++,
          }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
        }
      });

  /// The contact goes; their calls and conversations stay in the section
  /// (they are removed on their own screens).
  Future<void> delete(String id) => _db.transaction((txn) async {
    await txn.delete('hc_numbers', where: 'contact_id = ?', whereArgs: [id]);
    await txn.delete('hc_contacts', where: 'id = ?', whereArgs: [id]);
  });

  /// Every hidden number — what Kotlin gets as tags.
  Future<List<String>> allNumbers() async {
    final rows = await _db.rawQuery(
      'SELECT DISTINCT phone FROM hc_numbers ORDER BY phone',
    );
    return [for (final r in rows) r['phone'] as String];
  }

  /// Number → name, for the call screen while the section is open. A number
  /// under two contacts takes the first by name.
  Future<Map<String, String>> names() async {
    final rows = await _db.rawQuery('''
      SELECT n.phone, c.name FROM hc_numbers n
        JOIN hc_contacts c ON c.id = n.contact_id
       ORDER BY c.name COLLATE NOCASE DESC
    ''');
    return {for (final r in rows) r['phone'] as String: r['name'] as String};
  }

  Future<String?> nameFor(String phone) async {
    final rows = await _db.rawQuery(
      '''
      SELECT c.name FROM hc_numbers n JOIN hc_contacts c ON c.id = n.contact_id
       WHERE n.phone = ? ORDER BY c.name COLLATE NOCASE LIMIT 1
      ''',
      [phone],
    );
    return rows.isEmpty ? null : rows.first['name'] as String;
  }

  /// The contact holding [phone], other than [exceptId] — a number belongs
  /// to one hidden contact.
  Future<HiddenContact?> ownerOf(String phone, {String? exceptId}) async {
    final rows = await _db.query(
      'hc_numbers',
      columns: ['contact_id'],
      where: exceptId == null ? 'phone = ?' : 'phone = ? AND contact_id != ?',
      whereArgs: exceptId == null ? [phone] : [phone, exceptId],
      limit: 1,
    );
    if (rows.isEmpty) return null;
    return contact(rows.first['contact_id'] as String);
  }

  // ── Calls ────────────────────────────────────────────────────────────────

  /// Stores [records]; a call already stored is skipped. Returns how many
  /// were new.
  Future<int> addCalls(Iterable<HiddenCallRecord> records) async {
    var added = 0;
    await _db.transaction((txn) async {
      for (final r in records) {
        final id = await txn.insert('hc_calls', {
          'phone': r.phone,
          'call_type': r.callType,
          'timestamp': r.timestamp,
          'duration': r.duration,
          'account': r.account,
        }, conflictAlgorithm: cipher.ConflictAlgorithm.ignore);
        if (id > 0) added++;
      }
    });
    return added;
  }

  /// Newest first; only [phones]' when given.
  Future<List<HiddenCall>> calls({List<String>? phones}) async {
    final rows = await _db.query(
      'hc_calls',
      where: phones == null
          ? null
          : 'phone IN (${List.filled(phones.length, '?').join(',')})',
      whereArgs: phones,
      orderBy: 'timestamp DESC',
    );
    return [
      for (final r in rows)
        HiddenCall(
          id: r['id'] as int,
          phone: r['phone'] as String,
          callType: r['call_type'] as int,
          timestamp: r['timestamp'] as int,
          duration: r['duration'] as int?,
          account: r['account'] as String?,
        ),
    ];
  }

  Future<void> deleteCalls(Iterable<int> ids) async {
    final list = ids.toList();
    if (list.isEmpty) return;
    await _db.delete(
      'hc_calls',
      where: 'id IN (${List.filled(list.length, '?').join(',')})',
      whereArgs: list,
    );
  }

  Future<void> clearCalls() => _db.delete('hc_calls');

  // ── Rows ─────────────────────────────────────────────────────────────────

  Future<Map<String, List<HiddenNumber>>> _numbersByContact([
    String? id,
  ]) async {
    final rows = await _db.query(
      'hc_numbers',
      where: id == null ? null : 'contact_id = ?',
      whereArgs: id == null ? null : [id],
      orderBy: 'contact_id, position',
    );
    final out = <String, List<HiddenNumber>>{};
    for (final r in rows) {
      out
          .putIfAbsent(r['contact_id'] as String, () => [])
          .add(
            HiddenNumber(
              phone: r['phone'] as String,
              label: r['label'] as String?,
            ),
          );
    }
    return out;
  }

  HiddenContact _contact(Map<String, Object?> r, List<HiddenNumber> numbers) =>
      HiddenContact(
        id: r['id'] as String,
        name: r['name'] as String,
        note: r['note'] as String?,
        numbers: numbers,
        createdAt: r['created_at'] as int,
        updatedAt: r['updated_at'] as int,
      );
}
