import 'package:flutter/material.dart';

import '../screens/add_edit_contact_screen.dart';
import 'contact_picker_sheet.dart';

/// The two ways to keep a number that turned up somewhere — a call log row, a
/// message, a tapped number.
///
/// Google Phone and Google Contacts always offer **both**, and the second one
/// was missing here: «ایجاد مخاطب جدید» existed everywhere, «افزودن به مخاطب
/// موجود» nowhere. That is the more common case by far — a second number for
/// someone already in the address book — and without it the only way to record
/// one was to open Contacts, find the person and edit them by hand.
///
/// Both return true when a contact was actually saved, so the caller can
/// refresh the list the number came from (a saved number resolves to a name
/// there).

/// «ایجاد مخاطب جدید» — a new contact seeded with [phone].
Future<bool> createContactWithNumber(BuildContext context, String phone) async {
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => AddEditContactScreen(initialPhone: phone),
    ),
  );
  return saved == true;
}

/// «افزودن به مخاطب موجود» — pick a person, then open their editor with
/// [phone] already appended.
///
/// The editor is opened rather than the number being written silently: which
/// *label* the number gets (همراه / خانه / محل کار) is a real question, and a
/// silent write gives the user nowhere to answer it — or to notice they picked
/// the wrong person.
Future<bool> addNumberToExistingContact(
  BuildContext context,
  String phone,
) async {
  final picked = await showContactPickerSheet(
    context,
    title: 'افزودن به کدام مخاطب؟',
    // The whole point is that this contact does NOT have the number yet.
    pickNumber: false,
    // A SIM (ADN) record has no ContactsContract row to edit.
    editableOnly: true,
  );
  if (picked == null || !context.mounted) return false;
  final saved = await Navigator.of(context).push<bool>(
    MaterialPageRoute(
      builder: (_) => AddEditContactScreen(
        contactId: picked.contact.id,
        initialPhone: phone,
      ),
    ),
  );
  return saved == true;
}
