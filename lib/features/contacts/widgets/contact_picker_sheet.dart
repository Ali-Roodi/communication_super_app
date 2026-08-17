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
///
/// [pickNumber] false picks the **person** only, in one step, and lists people
/// with no number at all. That is what «افزودن به مخاطب موجود» needs: the whole
/// point there is that the contact does not have this number yet, so asking
/// which of their numbers to use would be asking the wrong question — and a
/// contact saved with only an e-mail would have been unreachable.
///
/// [editableOnly] drops SIM (ADN) contacts. An ADN record is one name and one
/// number on a card with a fixed field length — there is no ContactsContract
/// row to edit, so offering one as a target for "add this number to…" leads to
/// an editor that cannot open.
Future<PickedContactNumber?> showContactPickerSheet(
  BuildContext context, {
  String title = 'انتخاب مخاطب',
  bool pickNumber = true,
  bool editableOnly = false,
}) {
  return showModalBottomSheet<PickedContactNumber>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _ContactPickerSheet(
      title: title,
      pickNumber: pickNumber,
      editableOnly: editableOnly,
    ),
  );
}

class _ContactPickerSheet extends StatefulWidget {
  final String title;
  final bool pickNumber;
  final bool editableOnly;
  const _ContactPickerSheet({
    required this.title,
    required this.pickNumber,
    required this.editableOnly,
  });

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
                    // are not offered — unless the caller is picking a person
                    // to *give* a number to.
                    final reachable = [
                      for (final c in snapshot.data!)
                        if ((!widget.pickNumber || c.phoneNumbers.isNotEmpty) &&
                            (!widget.editableOnly || !c.isSimContact))
                          c,
                    ];
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
        if (!widget.pickNumber) {
          Navigator.of(
            context,
          ).pop(PickedContactNumber(contact: c, number: ''));
          return;
        }
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
