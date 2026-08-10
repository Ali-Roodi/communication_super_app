import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/sim/sim_card.dart';
import '../models/contact_model.dart';

/// Reads (and writes) the SIM address book, `content://icc/adn`.
///
/// **Why this exists at all:** SIM contacts are not in `ContactsContract`.
/// The Contacts provider only carries them when the device's *default*
/// contacts app has registered a SIM account and imported the card, which is
/// exactly what does not happen on a phone where this app is the contacts
/// surface. `flutter_contacts` therefore returns the same list with a second
/// SIM inserted as without one — the reported bug. Google Contacts reads the
/// ICC provider directly; so does this.
class SimContactsService {
  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/sim_contacts',
  );

  /// Every SIM's contacts, already shaped as [ContactModel]s tagged
  /// [ContactSource.sim].
  ///
  /// Never throws. A card that cannot be read — permission not granted yet, an
  /// OEM that hides the provider, a card still initialising — contributes
  /// nothing; the phone address book must still render.
  static Future<List<ContactModel>> read() async {
    try {
      final rows = await _channel.invokeMethod<List<dynamic>>('getSimContacts');
      if (rows == null || rows.isEmpty) return const <ContactModel>[];
      final now = DateTime.now();
      final out = <ContactModel>[];
      for (final row in rows) {
        if (row is! Map) continue;
        final map = Map<String, dynamic>.from(row);
        final number = (map['number'] as String? ?? '').trim();
        if (number.isEmpty) continue;
        final name = (map['name'] as String? ?? '').trim();
        out.add(
          ContactModel(
            id: map['id'] as String? ?? 'sim:$number',
            name: name.isEmpty ? 'بدون نام' : name,
            phoneNumber: number,
            phoneNumbers: [number],
            email: (map['email'] as String?)?.trim().isEmpty ?? true
                ? null
                : (map['email'] as String).trim(),
            createdAt: now,
            updatedAt: now,
            source: ContactSource.sim,
            simSubscriptionId: (map['subscriptionId'] as num?)?.toInt(),
          ),
        );
      }
      return out;
    } on PlatformException catch (e) {
      debugPrint('SIM contacts read failed: ${e.code} - ${e.message}');
      return const <ContactModel>[];
    } catch (e) {
      debugPrint('SIM contacts read failed: $e');
      return const <ContactModel>[];
    }
  }

  /// Writes one ADN record. False means the card refused it — a full card, or
  /// a name longer than the record allows. The caller must say so rather than
  /// reporting a save that did not happen.
  static Future<bool> insert({
    required int subscriptionId,
    required String name,
    required String number,
  }) async {
    if (number.trim().isEmpty) return false;
    try {
      return await _channel.invokeMethod<bool>('insertSimContact', {
            'subscriptionId': subscriptionId,
            'name': name.trim(),
            'number': number.trim(),
          }) ??
          false;
    } catch (e) {
      debugPrint('SIM contact insert failed: $e');
      return false;
    }
  }

  /// Deletes by content — the ICC provider accepts no other selection, because
  /// an ADN record has no id that survives a rewrite.
  static Future<bool> delete(ContactModel contact) async {
    final subId = contact.simSubscriptionId;
    if (!contact.isSimContact || subId == null) return false;
    try {
      return await _channel.invokeMethod<bool>('deleteSimContact', {
            'subscriptionId': subId,
            'name': contact.name == 'بدون نام' ? '' : contact.name,
            'number': contact.primaryPhone,
          }) ??
          false;
    } catch (e) {
      debugPrint('SIM contact delete failed: $e');
      return false;
    }
  }

  /// Whether writing to a SIM is offered at all. Only on a phone that has one.
  static bool canWriteTo(SimCard sim) =>
      sim.subscriptionId != SimCard.invalidSubscriptionId;
}
