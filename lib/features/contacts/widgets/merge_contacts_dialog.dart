import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';

import '../models/contact_model.dart';

/// The answer «ادغام» gives: go ahead, and keep this contact's name.
class MergeChoice {
  const MergeChoice(this.primaryContactId);

  /// The contact whose name and photo the merged contact shows.
  final String primaryContactId;
}

/// Confirms a merge **and asks which contact stays the main one**.
///
/// Linking never deletes anything (see `ContactLinkService`), so the only thing
/// really at stake is the name and photo the merged contact ends up wearing —
/// and until this dialog existed the provider decided that on its own, which
/// meant merging «علی» into «علی رودی» could just as easily produce «علی». One
/// question, asked where the decision is made, the way Google Contacts asks it.
///
/// Returns null when the user backed out.
Future<MergeChoice?> showMergeContactsDialog(
  BuildContext context, {
  required List<ContactModel> contacts,
}) {
  if (contacts.length < 2) return Future.value(null);
  return showDialog<MergeChoice>(
    context: context,
    builder: (ctx) => _MergeDialog(contacts: contacts),
  );
}

class _MergeDialog extends StatefulWidget {
  const _MergeDialog({required this.contacts});

  final List<ContactModel> contacts;

  @override
  State<_MergeDialog> createState() => _MergeDialogState();
}

class _MergeDialogState extends State<_MergeDialog> {
  /// Defaults to the contact with the most complete name — the longest one is
  /// a good proxy for «علی رودی» over «علی», and it is the pick a user who just
  /// presses «ادغام» almost always wants.
  late String _primary = widget.contacts
      .reduce((a, b) => b.name.trim().length > a.name.trim().length ? b : a)
      .id;

  @override
  Widget build(BuildContext context) {
    final count = PersianUtils.toPersianNumber('${widget.contacts.length}');
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('ادغام مخاطبین'),
        contentPadding: const EdgeInsets.fromLTRB(0, 16, 0, 0),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 24),
                child: Text(
                  '$count مخاطب به یک مخاطب تبدیل می‌شوند. هیچ شماره یا '
                  'اطلاعاتی حذف نمی‌شود و بعداً می‌توانید از صفحهٔ مخاطب '
                  'آن‌ها را جدا کنید.\n\nنام و عکس کدام‌یک بماند؟',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
              ),
              const SizedBox(height: 8),
              Flexible(
                child: SingleChildScrollView(
                  child: RadioGroup<String>(
                    groupValue: _primary,
                    onChanged: (v) => setState(() => _primary = v ?? _primary),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        for (final contact in widget.contacts)
                          RadioListTile<String>(
                            value: contact.id,
                            title: Text(contact.name),
                            subtitle: contact.phoneNumbers.isEmpty
                                ? null
                                : Padding(
                                    padding: const EdgeInsets.only(top: 3),
                                    child: ContactNumbersLine(
                                      numbers: contact.phoneNumbers,
                                    ),
                                  ),
                            secondary: LazyContactAvatar(
                              contactId: contact.id,
                              name: contact.name,
                              size: 36,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(MergeChoice(_primary)),
            child: const Text('ادغام'),
          ),
        ],
      ),
    );
  }
}
