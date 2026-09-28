import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/hidden_bloc.dart';
import '../repositories/hidden_contacts_repository.dart';
import 'hidden_contact_edit_screen.dart';
import 'hidden_contact_screen.dart';

/// «دفترچه مخفی»: contacts kept only in the secure section — never in the
/// system address book, so no other app can read them (matrix row 35).
class HiddenContactsScreen extends StatefulWidget {
  const HiddenContactsScreen({super.key});

  @override
  State<HiddenContactsScreen> createState() => _HiddenContactsScreenState();
}

class _HiddenContactsScreenState extends State<HiddenContactsScreen> {
  final _search = TextEditingController();
  String _query = '';

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<HiddenContact> _filter(List<HiddenContact> all) {
    final q = _query.trim();
    if (q.isEmpty) return all;
    final folded = SearchText.fold(q);
    final digits = PersianUtils.toEnglishNumber(
      q,
    ).replaceAll(RegExp(r'\D'), '');
    return [
      for (final c in all)
        if (SearchText.fold(c.name).contains(folded) ||
            (digits.isNotEmpty &&
                c.numbers.any((n) => n.phone.contains(digits))))
          c,
    ];
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<HiddenBloc, HiddenState>(
        builder: (context, state) {
          final ready = state.status == HiddenStatus.ready;
          return Scaffold(
            appBar: const RtlAppBar(title: 'دفترچه مخفی'),
            body: switch (state.status) {
              HiddenStatus.locked => const SecureLockedView(
                message:
                    'دفترچه مخفی داخل بخش امن نگهداری می‌شود. برای دیدن آن، '
                    'بخش امن را باز کنید.',
              ),
              HiddenStatus.loading => const SizedBox.shrink(),
              HiddenStatus.ready =>
                state.contacts.isEmpty
                    ? const _Empty()
                    : _List(
                        contacts: _filter(state.contacts),
                        search: _search,
                        onQuery: (q) => setState(() => _query = q),
                      ),
            },
            floatingActionButton: ready
                ? FloatingActionButton.extended(
                    heroTag: 'hidden_contacts_fab',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const HiddenContactEditScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.person_add_alt_1_outlined),
                    label: const Text('مخاطب مخفی'),
                  )
                : null,
          );
        },
      ),
    );
  }
}

class _List extends StatelessWidget {
  const _List({
    required this.contacts,
    required this.search,
    required this.onQuery,
  });

  final List<HiddenContact> contacts;
  final TextEditingController search;
  final ValueChanged<String> onQuery;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: const EdgeInsets.only(bottom: 96),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
          child: TextField(
            controller: search,
            decoration: const InputDecoration(
              hintText: 'جستجو در دفترچه مخفی',
              prefixIcon: Icon(Icons.search),
            ),
            onChanged: onQuery,
          ),
        ),
        if (contacts.isEmpty)
          Padding(
            padding: const EdgeInsets.all(32),
            child: Text(
              'نتیجه‌ای یافت نشد',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant),
            ),
          ),
        for (final c in contacts)
          ListTile(
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 4,
            ),
            leading: CircleAvatar(
              backgroundColor: scheme.primaryContainer,
              child: Text(
                PersianUtils.getInitials(c.name),
                style: TextStyle(color: scheme.onPrimaryContainer),
              ),
            ),
            title: Text(c.name, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text(
              numbersLine(c),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            onTap: () => Navigator.of(context).push(
              MaterialPageRoute(builder: (_) => HiddenContactScreen(id: c.id)),
            ),
          ),
      ],
    );
  }
}

/// «۰۹۱۲… · +۱», the same shape the ordinary contact rows use.
String numbersLine(HiddenContact c) {
  if (c.numbers.isEmpty) return '';
  final first = PersianUtils.displayPhone(c.numbers.first.phone);
  final more = c.numbers.length - 1;
  return more > 0
      ? '$first · +${PersianUtils.toPersianNumber('$more')}'
      : first;
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.contact_phone_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('دفترچه مخفی خالی است', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'مخاطبی که اینجا بگذارید در دفترچه تلفن گوشی نیست و تماس‌ها و '
              'پیامک‌هایش در سوابق گوشی ثبت نمی‌شود؛ فقط داخل بخش امن دیده '
              'می‌شود.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}
