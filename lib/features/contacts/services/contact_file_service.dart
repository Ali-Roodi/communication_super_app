
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import '../models/contact_model.dart';
import '../models/contact_save_target.dart';
import '../models/vcf_file.dart';
import 'sim_contacts_service.dart';

enum ContactFileFailure { tooLarge, failed }

class ContactFileException implements Exception {
  const ContactFileException(this.failure);
  final ContactFileFailure failure;
}

/// How many contacts an export wrote and how many it could not.
class ContactFileReport {
  const ContactFileReport(this.done, this.failed);
  final int done;
  final int failed;
}

/// Moves ordinary contacts to and from a `.vcf` file, a cloud account or a SIM.
///
/// Only the phone's address book and the SIMs pass through here. The hidden
/// phonebook and the key bank live in the secure section and never reach it.
class ContactFileService {
  const ContactFileService();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/contact_file',
  );

  static const String _targetKey = 'contact_save_target';

  // ── The default place ─────────────────────────────────────────────────

  /// Everywhere a contact can be written on this phone, the phone itself first.
  Future<List<ContactSaveTarget>> targets() async {
    var rows = const <dynamic>[];
    try {
      rows = await _channel.invokeMethod<List<dynamic>>('saveTargets') ?? rows;
    } on PlatformException catch (e) {
      debugPrint('contact save targets failed: ${e.code}');
    } on MissingPluginException {
      // Widget tests: the phone is enough.
    }
    return [
      const ContactSaveTarget.phone(),
      for (final sim in SimService.cached)
        ContactSaveTarget.sim(sim.subscriptionId),
      for (final row in rows.whereType<Map>())
        ContactSaveTarget.account(row['type'] as String, row['name'] as String),
    ];
  }

  /// The chosen default, or the phone once that place is gone: a card taken
  /// out, an account removed.
  Future<ContactSaveTarget> defaultTarget(
    List<ContactSaveTarget> available,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final stored = ContactSaveTarget.decode(prefs.getString(_targetKey));
    return stored != null && available.contains(stored)
        ? stored
        : const ContactSaveTarget.phone();
  }

  Future<void> setDefaultTarget(ContactSaveTarget target) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_targetKey, target.encode());
  }

  // ── File ──────────────────────────────────────────────────────────────

  /// Asks where to save. Null when the user cancelled.
  Future<String?> chooseExportFile() async {
    try {
      return await AppHandoff.run(
        () => _channel.invokeMethod<String>('createFile', {
          'name': 'hamresan-contacts.vcf',
        }),
      );
    } on PlatformException {
      throw const ContactFileException(ContactFileFailure.failed);
    }
  }

  Future<ContactFileReport> writeExportFile(
    String uri,
    List<ContactModel> contacts,
  ) async {
    final device = [
      for (final c in contacts)
        if (!c.isSimContact) c.id,
    ];
    final sim = [
      for (final c in contacts)
        if (c.isSimContact) _simCard(c),
    ];
    try {
      final result = await _channel.invokeMapMethod<String, dynamic>(
        'writeFile',
        {'uri': uri, 'ids': device, 'extra': sim},
      );
      return ContactFileReport(
        (result?['written'] as num?)?.toInt() ?? 0,
        (result?['failed'] as num?)?.toInt() ?? contacts.length,
      );
    } on PlatformException {
      throw const ContactFileException(ContactFileFailure.failed);
    }
  }

  /// A SIM record has no row in the contacts provider to export from.
  String _simCard(ContactModel contact) {
    final card = Contact(
      displayName: contact.name,
      name: Name(first: contact.name),
      phones: [Phone(contact.phoneNumber)],
    );
    return '${card.toVCard()}\r\n';
  }

  /// The chosen file's bytes. Null when the user cancelled.
  Future<Uint8List?> pickImportFile() async {
    try {
      return await AppHandoff.run(
        () => _channel.invokeMethod<Uint8List>('pick'),
      );
    } on PlatformException catch (e) {
      throw ContactFileException(
        e.code == 'TOO_LARGE'
            ? ContactFileFailure.tooLarge
            : ContactFileFailure.failed,
      );
    }
  }

  Future<VcfParseResult> parse(Uint8List bytes) =>
      compute(VcfFile.parse, bytes);

  // ── Writing a contact ─────────────────────────────────────────────────

  /// Writes [contact] as a new contact in [target]. False when a SIM refused
  /// it. A SIM record holds one name and one number and nothing else.
  Future<bool> insert(Contact contact, ContactSaveTarget target) async {
    if (target.isSim) {
      if (contact.phones.isEmpty) return false;
      // The card sets the length and only refuses, without saying what it
      // would take: often 14 Latin letters, half that in Persian.
      for (final name in simNames(contact.displayName)) {
        final saved = await SimContactsService.insert(
          subscriptionId: target.subscriptionId!,
          name: name,
          number: contact.phones.first.number,
        );
        if (saved) return true;
      }
      return false;
    }
    contact
      ..id = ''
      // The same crash as in `AddEditContactScreen._save`: never hand the
      // plugin group rows, which belong to another account anyway.
      ..groups = []
      ..accounts = target.isAccount
          ? [Account('', target.accountType!, target.accountName!, const [])]
          : [];
    if ((contact.photo?.length ?? 0) > VcfFile.maxPhotoBytes) {
      contact.photo = contact.thumbnail;
    }
    await FlutterContacts.insertContact(contact);
    return true;
  }

  /// [name], then shorter, for a card that refuses the longer one.
  @visibleForTesting
  static List<String> simNames(String name) {
    final characters = name.trim().characters;
    return {
      name.trim(),
      for (final length in const [14, 6])
        if (characters.length > length)
          characters.take(length).toString().trim(),
    }.toList();
  }

  /// Copies [contacts] into [target]. The originals stay where they are, and
  /// the phone shows a copy with the same name and number as one contact.
  Future<ContactFileReport> copy(
    List<ContactModel> contacts,
    ContactSaveTarget target, {
    void Function(int done)? onProgress,
  }) async {
    var done = 0;
    var failed = 0;
    for (final model in contacts) {
      try {
        final contact = model.isSimContact
            ? Contact(
                displayName: model.name,
                name: Name(first: model.name),
                phones: [Phone(model.phoneNumber)],
              )
            : await FlutterContacts.getContact(
                model.id,
                withProperties: true,
                withPhoto: true,
                withThumbnail: true,
                withAccounts: true,
              );
        if (contact == null || !await _copyOne(contact, target)) {
          failed++;
        } else {
          done++;
        }
      } catch (e) {
        debugPrint('contact copy failed: ${e.runtimeType}');
        failed++;
      }
      onProgress?.call(done + failed);
    }
    return ContactFileReport(done, failed);
  }

  /// A contact already in that place counts as copied.
  Future<bool> _copyOne(Contact contact, ContactSaveTarget target) async {
    final already = contact.accounts.any(
      (a) => target.isAccount
          ? a.type == target.accountType && a.name == target.accountName
          : target.isPhone && isPhoneAccountType(a.type),
    );
    return already || await insert(contact, target);
  }

  /// A raw contact with no account, or in the store a maker keeps on the phone
  /// (`vnd.sec.contact.phone`, `com.android.huawei.phone`, …).
  @visibleForTesting
  static bool isPhoneAccountType(String type) =>
      type.isEmpty || type.toLowerCase().contains('phone');
}
