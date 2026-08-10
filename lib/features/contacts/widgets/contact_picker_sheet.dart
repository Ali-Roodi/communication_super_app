import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';

import '../models/contact_model.dart';
import '../repositories/contact_repository.dart';
import 'phone_number_picker.dart';

/// One number of one contact, as picked out of [showContactPickerSheet].
class PickedContactNumber {
  final ContactModel contact;
  final String number;
  const PickedContactNumber({required this.contact, required this.number});
}

/// "Choose a contact, then which of their numbers" — the sheet behind every
/// assignment in the app that is really a *number*, not a person: a speed-dial
/// key, a favourite.
///
/// It goes through [ContactRepository.matchContacts], so «علي» finds «علی» and
/// `0912…` finds a contact stored as `+98912…` — a picker with its own
/// `String.contains` filter is a picker that cannot find half the address book.
///
/// Returns null when the user dismissed either step.
Future<PickedContactNumber?> showContactPickerSheet(
  BuildContext context, {
  String title = 'انتخاب مخاطب',
}) {
  return showModalBottomSheet<PickedContactNumber>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ContactPickerSheet(title: title),
  );
}

class _ContactPickerSheet extends StatefulWidget {
  final String title;
  const _ContactPickerSheet({required this.title});

  @override
  State<_ContactPickerSheet> createState() => _ContactPickerSheetState();
}

class _ContactPickerSheetState extends State<_ContactPickerSheet> {
  late final Future<List<ContactModel>> _contacts = ContactRepository()
      .getAllContacts();
  String _query = '';

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
        ),
        child: SizedBox(
          height: MediaQuery.of(context).size.height * 0.7,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                child: TextField(
                  onChanged: (v) => setState(() => _query = v),
                  decoration: InputDecoration(
                    hintText: widget.title,
                    prefixIcon: const Icon(Icons.search),
                    isDense: true,
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(28),
                    ),
                  ),
                ),
              ),
              Expanded(
                child: FutureBuilder<List<ContactModel>>(
                  future: _contacts,
                  builder: (context, snapshot) {
                    if (!snapshot.hasData) {
                      return const Center(child: CircularProgressIndicator());
                    }
                    // A key that dials needs a number, so contacts without one
                    // are not offered.
                    final reachable = snapshot.data!
                        .where((c) => c.phoneNumbers.isNotEmpty)
                        .toList();
                    final results = ContactRepository.matchContacts(
                      reachable,
                      _query,
                    );
                    if (results.isEmpty) {
                      return const Center(child: Text('مخاطبی یافت نشد'));
                    }
                    final phoneQuery = PhoneQuery(_query);
                    return ListView.builder(
                      itemCount: results.length,
                      itemBuilder: (context, i) =>
                          _row(context, results[i], phoneQuery),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _row(BuildContext context, ContactModel c, PhoneQuery phoneQuery) {
    final matched = phoneQuery.isEmpty
        ? null
        : c.phoneNumbers.firstWhere(phoneQuery.contains, orElse: () => '');
    return ListTile(
      leading: LazyContactAvatar(contactId: c.id, name: c.name, size: 40),
      title: Text(c.name),
      subtitle: Padding(
        padding: const EdgeInsets.only(top: 3),
        child: ContactNumbersLine(
          numbers: c.phoneNumbers,
          matched: (matched == null || matched.isEmpty) ? null : matched,
          query: SearchText.digits(_query),
        ),
      ),
      onTap: () async {
        final number = await pickContactNumber(
          context,
          numbers: c.phoneNumbers,
          title: 'کدام شماره ${c.name}؟',
        );
        if (number == null || !context.mounted) return;
        Navigator.of(
          context,
        ).pop(PickedContactNumber(contact: c, number: number));
      },
    );
  }
}
