import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

/// One label as the user thinks of it: a name.
///
/// The provider does not agree. Every account on the phone — the Google one, the
/// phone-local one, WhatsApp's, the SIM's — carries its **own** «Family», its
/// own «Coworkers», its own «My Contacts», so a raw `getGroups()` on a normal
/// device answers with the same three names four times over. Listing that is not
/// a labels screen, it is a dump of the provider.
///
/// So a label is a name plus **every group id that carries it**: one row on
/// screen, and reads/writes fan out to all of them.
class ContactLabel {
  const ContactLabel(this.name, this.ids);

  final String name;

  /// Group ids with this name, one per account holding it.
  final List<String> ids;

  bool owns(String groupId) => ids.contains(groupId);
}

/// Contact labels («برچسب‌ها» — groups in ContactsContract terms).
///
/// Labels are *not* the app's favourites: they live in the device address book,
/// sync with the account that owns them, and are what every other contacts app
/// on the phone sees.
class ContactGroupsService {
  ContactGroupsService._();
  static final ContactGroupsService instance = ContactGroupsService._();

  /// Groups the platform maintains for itself. They are not labels anyone
  /// applies: «My Contacts» is "every contact", and «Starred in Android» is the
  /// favourites store the star already writes to. Google Contacts does not list
  /// them either.
  static const Set<String> _internalNames = {
    'my contacts',
    'starred in android',
  };

  /// Whether [name] is one of the platform's own groups rather than a label
  /// anyone applied.
  static bool isInternal(String name) =>
      _internalNames.contains(name.trim().toLowerCase());

  /// The label names to *show* for a contact: the platform's own groups
  /// dropped, duplicates (one per account) collapsed.
  static List<String> visibleNames(Iterable<Group> groups) {
    final names = <String>[];
    for (final group in groups) {
      final name = group.name.trim();
      if (name.isEmpty || isInternal(name) || names.contains(name)) continue;
      names.add(name);
    }
    return names;
  }

  List<Group>? _raw;

  /// Every label, deduplicated by name and sorted. Empty when contacts
  /// permission was refused — a label list that throws would take the editor
  /// down with it.
  Future<List<ContactLabel>> getLabels({bool forceRefresh = false}) async {
    final groups = await _rawGroups(forceRefresh: forceRefresh);
    final byName = <String, List<String>>{};
    for (final group in groups) {
      final name = group.name.trim();
      if (name.isEmpty) continue;
      if (_internalNames.contains(name.toLowerCase())) continue;
      byName.putIfAbsent(name, () => []).add(group.id);
    }
    final labels = [
      for (final entry in byName.entries) ContactLabel(entry.key, entry.value),
    ];
    labels.sort((a, b) => a.name.compareTo(b.name));
    return labels;
  }

  Future<List<Group>> _rawGroups({bool forceRefresh = false}) async {
    final cached = _raw;
    if (cached != null && !forceRefresh) return cached;
    try {
      final groups = await FlutterContacts.getGroups();
      _raw = groups;
      return groups;
    } catch (e) {
      debugPrint('ContactGroupsService: getGroups failed: $e');
      return const [];
    }
  }

  void invalidate() => _raw = null;

  /// The labels [contact] carries, resolved through the deduplicated list, so a
  /// contact tagged in one account lights up the single row on screen.
  Future<List<ContactLabel>> labelsOf(Contact contact) async {
    if (contact.groups.isEmpty) return const [];
    final labels = await getLabels();
    final ids = {for (final g in contact.groups) g.id};
    return labels.where((l) => l.ids.any(ids.contains)).toList();
  }

  /// The `Group` to write for [label] on a contact.
  ///
  /// Prefers an id the contact **already** carries, so saving does not move the
  /// tag from the account that owns it to another one; otherwise the first id.
  Group groupFor(ContactLabel label, {List<Group> existing = const []}) {
    for (final group in existing) {
      if (label.owns(group.id)) return group;
    }
    return Group(label.ids.first, label.name);
  }

  /// Native side — see `ContactGroupsHandler`. Everything that *writes* a
  /// membership, and label creation itself, goes through it: a group belongs to
  /// an account and `flutter_contacts` writes it without one, which is why a
  /// label made in this app used to come back empty however many contacts were
  /// put in it.
  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/contact_groups',
  );

  /// Creates a label and returns it, or null when the platform refused.
  ///
  /// Created **in a real account** (the one most of the phone's contacts live
  /// in). A group with no account is one no raw contact can legally join, so
  /// the label would exist and stay permanently empty.
  ///
  /// A name that already exists is not blocked here: the provider allows it, and
  /// second-guessing that would mean disagreeing with Google Contacts about the
  /// same address book. It lands in the existing row anyway, since labels are
  /// keyed by name.
  Future<ContactLabel?> create(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return null;
    try {
      final id = await _channel.invokeMethod<String>('createLabel', {
        'name': trimmed,
      });
      invalidate();
      if (id == null) return null;
      return ContactLabel(trimmed, [id]);
    } catch (e) {
      debugPrint('ContactGroupsService: createLabel failed: $e');
      return null;
    }
  }

  /// Makes [contactId] carry exactly [names] (the platform's own groups are
  /// left alone).
  ///
  /// Used by the editor instead of `Contact.update(withGroups: true)`, which
  /// deletes every membership row of the whole aggregate and re-adds them
  /// against the first raw contact only — so editing a linked contact dropped
  /// the labels its other accounts carried.
  Future<bool> applyLabels(String contactId, List<String> names) async {
    if (contactId.isEmpty) return false;
    try {
      final ok = await _channel.invokeMethod<bool>('applyLabels', {
        'contactId': contactId,
        'names': names,
      });
      invalidate();
      return ok ?? false;
    } catch (e) {
      debugPrint('ContactGroupsService: applyLabels failed: $e');
      return false;
    }
  }

  /// Adds contacts to a label, creating it in each contact's own account when
  /// that account does not have it yet. Returns how many were added.
  Future<int> addToLabel(String name, List<String> contactIds) async {
    if (name.trim().isEmpty || contactIds.isEmpty) return 0;
    try {
      final added = await _channel.invokeMethod<int>('addToLabel', {
        'name': name.trim(),
        'contactIds': contactIds,
      });
      invalidate();
      return added ?? 0;
    } catch (e) {
      debugPrint('ContactGroupsService: addToLabel failed: $e');
      return 0;
    }
  }

  /// Takes contacts out of a label. The contacts themselves are untouched.
  Future<int> removeFromLabel(String name, List<String> contactIds) async {
    if (name.trim().isEmpty || contactIds.isEmpty) return 0;
    try {
      final removed = await _channel.invokeMethod<int>('removeFromLabel', {
        'name': name.trim(),
        'contactIds': contactIds,
      });
      invalidate();
      return removed ?? 0;
    } catch (e) {
      debugPrint('ContactGroupsService: removeFromLabel failed: $e');
      return 0;
    }
  }

  /// The device-contact ids carrying [label], read straight from the Data
  /// table.
  ///
  /// Returns null when the native side is unavailable, so the caller can fall
  /// back to the (much slower) full address-book read rather than showing an
  /// empty label.
  Future<List<String>?> memberIds(ContactLabel label) async {
    try {
      final ids = await _channel.invokeMethod<List<Object?>>('memberIds', {
        'name': label.name,
      });
      if (ids == null) return null;
      return [for (final id in ids) id as String];
    } catch (e) {
      debugPrint('ContactGroupsService: memberIds failed: $e');
      return null;
    }
  }

  /// Renames every account's copy of the label, so the row does not split in
  /// two the moment it is renamed.
  Future<bool> rename(ContactLabel label, String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty || trimmed == label.name) return false;
    var ok = false;
    for (final id in label.ids) {
      try {
        await FlutterContacts.updateGroup(Group(id, trimmed));
        ok = true;
      } catch (e) {
        debugPrint('ContactGroupsService: updateGroup failed: $e');
      }
    }
    invalidate();
    return ok;
  }

  /// Deletes the label from every account. The contacts that carried it are
  /// untouched — a label is a tag, and deleting a tag is not deleting the people
  /// wearing it.
  Future<bool> delete(ContactLabel label) async {
    var ok = false;
    for (final id in label.ids) {
      try {
        await FlutterContacts.deleteGroup(Group(id, label.name));
        ok = true;
      } catch (e) {
        debugPrint('ContactGroupsService: deleteGroup failed: $e');
      }
    }
    invalidate();
    return ok;
  }

  /// Contacts carrying [label], in any account.
  ///
  /// Read on demand rather than kept in the app's contact cache: groups are an
  /// opt-in join in the provider (`withGroups`), and paying for it on every
  /// address-book read would slow every screen down for one that is rarely
  /// opened.
  Future<List<Contact>> membersOf(ContactLabel label) async {
    try {
      final contacts = await FlutterContacts.getContacts(
        withProperties: true,
        withGroups: true,
      );
      return contacts
          .where((c) => c.groups.any((g) => label.owns(g.id)))
          .toList();
    } catch (e) {
      debugPrint('ContactGroupsService: membersOf failed: $e');
      return const [];
    }
  }
}
