import 'package:equatable/equatable.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';
import 'package:communication_super_app/features/contacts/services/contact_groups_service.dart';

enum ContactFilterKind { label, messenger, secure }

/// One chip of the filter row on the contacts tab and the inbox (matrix row
/// 36): a label («برچسب»), a messenger that keeps a copy of the address book,
/// or — in a secure edition, only while the section is open — «رمز», the
/// people with an encrypted conversation.
class ContactFilter extends Equatable {
  const ContactFilter._(this.kind, this.key, this.title, [this.icon]);

  factory ContactFilter.label(String name) =>
      ContactFilter._(ContactFilterKind.label, name, name);

  factory ContactFilter.messenger(MessengerAccount account) => ContactFilter._(
    ContactFilterKind.messenger,
    account.key,
    account.label,
    account.icon,
  );

  static const ContactFilter secure = ContactFilter._(
    ContactFilterKind.secure,
    'secure',
    'رمز',
  );

  final ContactFilterKind kind;

  /// The label's name, the messenger's account type, or `secure`.
  final String key;
  final String title;

  /// A messenger's app icon (PNG); null for the others.
  final Uint8List? icon;

  /// What a hidden chip is remembered by.
  String get id => '${kind.name}:$key';

  @override
  List<Object?> get props => [kind, key];
}

/// The groups the filter row offers, which of them the user hid, and who is
/// in each.
///
/// Labels come from [ContactGroupsService], messengers from
/// [ContactExtrasService.getMessengerAccounts]; «رمز» is decided by the caller
/// from the secure section's conversations ([secureMembers]), because that
/// list exists only while the section is open and must not be kept anywhere
/// else. [revision] is bumped whenever any of it changes.
class ContactFilters {
  ContactFilters._();

  static final ContactFilters instance = ContactFilters._();

  static const _hiddenKey = 'contact_filters_hidden';

  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  List<ContactLabel> _labels = const [];
  List<MessengerAccount> _messengers = const [];
  Set<String> _hidden = const {};
  final Map<String, Set<String>> _labelMembers = {};

  Future<void>? _loading;

  /// Re-reads the labels, the messengers and the hidden set. Concurrent calls
  /// share one read.
  Future<void> load() => _loading ??= _load().whenComplete(() {
    _loading = null;
  });

  Future<void> _load() async {
    try {
      final results = await Future.wait<Object>([
        ContactGroupsService.instance.getLabels(forceRefresh: true),
        ContactExtrasService.instance.getMessengerAccounts(),
        SharedPreferences.getInstance(),
      ]);
      _labels = results[0] as List<ContactLabel>;
      _messengers = results[1] as List<MessengerAccount>;
      final prefs = results[2] as SharedPreferences;
      _hidden = (prefs.getStringList(_hiddenKey) ?? const []).toSet();
      _labelMembers.clear();
    } catch (e) {
      debugPrint('ContactFilters.load failed: $e');
    }
    revision.value++;
  }

  /// Every filter there is: labels, then [messengers] (the inbox has none —
  /// a messenger is not a conversation), then «رمز» while [secureOpen].
  List<ContactFilter> all({required bool secureOpen, bool messengers = true}) =>
      [
        for (final label in _labels) ContactFilter.label(label.name),
        if (messengers)
          for (final account in _messengers) ContactFilter.messenger(account),
        if (secureOpen) ContactFilter.secure,
      ];

  /// [all] without the ones the user hid.
  List<ContactFilter> visible({
    required bool secureOpen,
    bool messengers = true,
  }) => [
    for (final f in all(secureOpen: secureOpen, messengers: messengers))
      if (!_hidden.contains(f.id)) f,
  ];

  bool isHidden(ContactFilter filter) => _hidden.contains(filter.id);

  Future<void> setHidden(ContactFilter filter, bool hidden) async {
    final next = {..._hidden};
    hidden ? next.add(filter.id) : next.remove(filter.id);
    _hidden = next;
    revision.value++;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_hiddenKey, next.toList()..sort());
  }

  /// The device-contact ids in a label or a messenger; null for «رمز» (see
  /// [secureMembers]) or when the provider cannot be read.
  Future<Set<String>?> contactIds(ContactFilter filter) async {
    switch (filter.kind) {
      case ContactFilterKind.messenger:
        for (final account in _messengers) {
          if (account.key == filter.key) return account.contactIds;
        }
        return const {};
      case ContactFilterKind.label:
        final cached = _labelMembers[filter.key];
        if (cached != null) return cached;
        for (final label in _labels) {
          if (label.name != filter.key) continue;
          final ids = await ContactGroupsService.instance.memberIds(label);
          if (ids == null) return null;
          return _labelMembers[filter.key] = ids.toSet();
        }
        return const {};
      case ContactFilterKind.secure:
        return null;
    }
  }

  /// The contacts with a number among [phones] — the «رمز» filter, fed the
  /// secure section's encrypted conversations.
  static Set<String> secureMembers(
    Iterable<ContactModel> contacts,
    Iterable<String> phones,
  ) {
    final wanted = {for (final p in phones) PhoneNormalizer.toThreadId(p)};
    if (wanted.isEmpty) return const {};
    return {
      for (final c in contacts)
        if (numbersOf(c).any(wanted.contains)) c.id,
    };
  }

  /// [contact]'s numbers as thread ids — what an inbox filter compares.
  static Iterable<String> numbersOf(ContactModel contact) => {
    for (final n in [contact.phoneNumber, ...contact.phoneNumbers])
      if (n.trim().isNotEmpty) PhoneNormalizer.toThreadId(n),
  };

  @visibleForTesting
  void debugSet({
    List<ContactLabel>? labels,
    List<MessengerAccount>? messengers,
    Set<String>? hidden,
    Map<String, Set<String>>? labelMembers,
  }) {
    if (labels != null) _labels = labels;
    if (messengers != null) _messengers = messengers;
    if (hidden != null) _hidden = hidden;
    if (labelMembers != null) {
      _labelMembers
        ..clear()
        ..addAll(labelMembers);
    }
    revision.value++;
  }
}
