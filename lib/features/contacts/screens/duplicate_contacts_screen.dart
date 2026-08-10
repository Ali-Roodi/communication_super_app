import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../models/contact_model.dart';
import '../repositories/contact_repository.dart';
import '../services/contact_link_service.dart';

/// «مخاطب‌های تکراری» — the same person, saved twice.
///
/// Duplicates are what an address book collects: one row from a SIM import, one
/// typed by hand, one that a messenger created. Selecting them by hand in the
/// contacts tab means finding them first, which on a long list is the whole
/// problem. This screen does the finding; the merge itself is the same
/// [ContactLinkService.link] the selection bar calls.
class DuplicateContactsScreen extends StatefulWidget {
  const DuplicateContactsScreen({super.key});

  @override
  State<DuplicateContactsScreen> createState() =>
      _DuplicateContactsScreenState();
}

class _DuplicateContactsScreenState extends State<DuplicateContactsScreen> {
  late Future<List<List<ContactModel>>> _groups;

  /// Groups merged in this visit, so a merged card can leave the list without
  /// re-reading the whole address book on every tap.
  final Set<int> _merged = {};

  @override
  void initState() {
    super.initState();
    _groups = _findDuplicates();
  }

  /// Contacts that are the same person, grouped.
  ///
  /// Two rows are the same person when they **share a number** (canonical form,
  /// so `+98912…` and `0912…` count) or carry the **same folded name** («علي» ≡
  /// «علی»). Both rules are needed and neither alone is enough: a duplicate
  /// typed by hand usually has one of the two numbers, and a SIM import usually
  /// keeps the number but mangles the name.
  ///
  /// Grouping is transitive — A shares a number with B, B shares a name with C,
  /// so all three are one person — which is what a union-find gives and what a
  /// naive "index by number" pass does not.
  Future<List<List<ContactModel>>> _findDuplicates() async {
    final all = await ContactRepository().getAllContacts();
    // A SIM contact has no ContactsContract row, so it cannot be aggregated;
    // listing it here would offer a merge that silently does nothing.
    final contacts = all.where((c) => !c.isSimContact).toList();

    final parent = List<int>.generate(contacts.length, (i) => i);
    int find(int i) {
      while (parent[i] != i) {
        parent[i] = parent[parent[i]];
        i = parent[i];
      }
      return i;
    }

    void union(int a, int b) {
      final ra = find(a);
      final rb = find(b);
      if (ra != rb) parent[rb] = ra;
    }

    final byNumber = <String, int>{};
    final byName = <String, int>{};
    for (var i = 0; i < contacts.length; i++) {
      final contact = contacts[i];
      for (final phone in contact.phoneNumbers) {
        final key = PhoneNormalizer.toThreadId(phone);
        if (key.isEmpty) continue;
        final seen = byNumber[key];
        if (seen == null) {
          byNumber[key] = i;
        } else {
          union(seen, i);
        }
      }
      final name = SearchText.foldTight(contact.name);
      // A blank or one-character name is not evidence of anything.
      if (name.length < 2) continue;
      final seen = byName[name];
      if (seen == null) {
        byName[name] = i;
      } else {
        union(seen, i);
      }
    }

    final groups = <int, List<ContactModel>>{};
    for (var i = 0; i < contacts.length; i++) {
      groups.putIfAbsent(find(i), () => []).add(contacts[i]);
    }
    return groups.values.where((g) => g.length > 1).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'مخاطب‌های تکراری'),
        body: FutureBuilder<List<List<ContactModel>>>(
          future: _groups,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final groups = snapshot.data!;
            final remaining = [
              for (var i = 0; i < groups.length; i++)
                if (!_merged.contains(i)) i,
            ];
            if (remaining.isEmpty) {
              return const EmptyState(
                icon: Icons.done_all,
                title: 'مخاطب تکراری‌ای پیدا نشد',
                subtitle: 'هر مخاطب فقط یک بار ذخیره شده است',
              );
            }
            return ListView.builder(
              padding: const EdgeInsets.only(bottom: 24),
              itemCount: remaining.length,
              itemBuilder: (context, i) =>
                  _groupCard(remaining[i], groups[remaining[i]]),
            );
          },
        ),
      ),
    );
  }

  Widget _groupCard(int index, List<ContactModel> group) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 0),
      child: GroupedList(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '${PersianUtils.toPersianNumber('${group.length}')} مخاطب مثل هم',
              style: theme.textTheme.titleSmall,
            ),
          ),
          for (final contact in group)
            ListTile(
              leading: LazyContactAvatar(
                contactId: contact.id,
                name: contact.name,
                size: 40,
              ),
              title: Text(contact.name),
              subtitle: Padding(
                padding: const EdgeInsets.only(top: 3),
                child: ContactNumbersLine(numbers: contact.phoneNumbers),
              ),
            ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
              child: TextButton.icon(
                icon: const Icon(Icons.merge_type),
                label: const Text('ادغام'),
                onPressed: () => _merge(index, group),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _merge(int index, List<ContactModel> group) async {
    final messenger = ScaffoldMessenger.of(context);
    final contactBloc = context.read<ContactBloc>();
    final merged = await ContactLinkService.instance.link([
      for (final c in group) c.id,
    ]);
    ContactRepository().invalidateCache();
    LazyContactAvatar.invalidateCache();
    if (!mounted) return;
    if (merged == null) {
      messenger.showSnackBar(const SnackBar(content: Text('ادغام ممکن نشد')));
      return;
    }
    setState(() => _merged.add(index));
    contactBloc.add(const RefreshContacts());
    messenger.showSnackBar(
      const SnackBar(content: Text('مخاطبین ادغام شدند')),
    );
  }
}
