import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';

/// One row of the number picker: the number, the label it was saved under
/// («موبایل» / «محل کار»), and whether it is the contact's default.
class PickablePhone {
  final String number;

  /// «موبایل», «منزل» … Null renders the row without a second line.
  final String? label;

  /// The contact's `IS_SUPER_PRIMARY` number — drawn with a «پیش‌فرض» chip and
  /// listed first, exactly as Google Contacts does.
  final bool isDefault;

  const PickablePhone({
    required this.number,
    this.label,
    this.isDefault = false,
  });
}

/// Asks which of a contact's numbers to act on, the way Google Contacts does
/// when a contact has more than one.
///
/// Returns the chosen number, or null when the user dismissed the sheet. A
/// contact with a single number resolves immediately — never make the user
/// confirm a choice they don't have — and one with none returns null.
///
/// [entries] is the richer form: each row carries its label and whether it is
/// the default, which is what makes the sheet answerable at a glance («کدام
/// شماره؟» is not a question about digits, it is a question about *which
/// phone*). [numbers] stays for the callers that only hold bare strings.
Future<String?> pickContactNumber(
  BuildContext context, {
  List<String> numbers = const [],
  List<PickablePhone> entries = const [],
  required String title,
}) async {
  final rows = entries.isNotEmpty
      ? entries.where((e) => e.number.trim().isNotEmpty).toList()
      : [
          for (final n in numbers)
            if (n.trim().isNotEmpty) PickablePhone(number: n),
        ];
  if (rows.isEmpty) return null;
  if (rows.length == 1) return rows.first.number;

  // **A default number is an answer, not a hint.** Google Contacts asks which
  // number only while the contact has no default; once «تنظیم به‌عنوان شماره
  // پیش‌فرض» has been used, تماس/پیام go straight to that line and the sheet is
  // not shown at all — the setting exists precisely to stop being asked.
  //
  // Showing it anyway (with the default merely sorted to the top and wearing a
  // «پیش‌فرض» chip) is what the user reported: a line was pinned as the
  // default and every call and message still opened the picker, so the setting
  // read as decorative. The explicit override is unchanged — a long-press on
  // the call button still asks, and the number rows further down a contact page
  // still dial themselves.
  //
  // Exactly one, never "the first one flagged": `IS_SUPER_PRIMARY` is one row
  // per contact, and a contact that somehow carries two has no default worth
  // acting on, so that falls back to asking.
  final defaults = rows.where((r) => r.isDefault);
  if (defaults.length == 1) return defaults.first.number;

  // The default first: it is the answer the user gives most of the time, and
  // burying it under the order the address book happens to store makes the
  // "default" pointless at the exact moment it is being used.
  rows.sort((a, b) {
    if (a.isDefault == b.isDefault) return 0;
    return a.isDefault ? -1 : 1;
  });

  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) {
      final theme = Theme.of(sheetCtx);
      return Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
                child: Text(title, style: theme.textTheme.titleMedium),
              ),
              for (final row in rows)
                ListTile(
                  leading: const Icon(Icons.phone_outlined),
                  title: Directionality(
                    // A phone number is left-to-right content; in an RTL
                    // paragraph a leading «+» lands at the wrong end.
                    textDirection: TextDirection.ltr,
                    child: Text(
                      PersianUtils.displayPhone(row.number),
                      textAlign: TextAlign.right,
                    ),
                  ),
                  subtitle: row.label == null ? null : Text(row.label!),
                  trailing: row.isDefault
                      ? Chip(
                          label: const Text('پیش‌فرض'),
                          labelStyle: theme.textTheme.labelSmall,
                          visualDensity: VisualDensity.compact,
                          materialTapTargetSize:
                              MaterialTapTargetSize.shrinkWrap,
                          side: BorderSide.none,
                          backgroundColor: theme.colorScheme.secondaryContainer,
                        )
                      : null,
                  onTap: () => Navigator.pop(sheetCtx, row.number),
                ),
            ],
          ),
        ),
      );
    },
  );
}

/// [pickContactNumber] for a caller that holds a *contact* rather than a
/// prepared list of rows: it reads the contact's default number first, so a
/// person with a pinned line is never asked which one to use.
///
/// The read is the platform's own `IS_SUPER_PRIMARY`
/// (`ContactExtrasService.getDefaultPhone`) — the same column Google Contacts
/// writes from «تنظیم به‌عنوان شماره پیش‌فرض» and the same one the contact page
/// already honours. Doing it here is what makes «موردعلاقه‌ها», «جستجو» and
/// «گفتگوی جدید» agree with the contact page instead of each asking again for a
/// question the user has already answered.
///
/// One platform call, made at gesture time on a contact with more than one
/// number — never during a build and never for the common single-number case.
/// A refusal (no permission, an older provider) simply falls back to asking.
Future<String?> pickContactNumberFor(
  BuildContext context, {
  required String? contactId,
  required List<String> numbers,
  required String title,
}) async {
  final rows = [
    for (final n in numbers)
      if (n.trim().isNotEmpty) n.trim(),
  ];
  if (rows.isEmpty) return null;
  if (rows.length == 1) return rows.first;

  String? preferred;
  if (contactId != null && contactId.isNotEmpty) {
    preferred = await ContactExtrasService.instance.getDefaultPhone(contactId);
  }
  if (!context.mounted) return null;

  return pickContactNumber(
    context,
    entries: [
      for (final n in rows)
        PickablePhone(number: n, isDefault: _sameNumber(preferred, n)),
    ],
    title: title,
  );
}

/// Compared on the last nine digits, exactly as the contact page does: the
/// provider hands the default back as the user typed it while the list here
/// carries whatever formatting each row was saved with, so `==` never matches.
bool _sameNumber(String? a, String b) {
  if (a == null) return false;
  final left = _tailDigits(a);
  return left.isNotEmpty && left == _tailDigits(b);
}

String _tailDigits(String raw) {
  final digits = raw.replaceAll(RegExp(r'\D'), '');
  return digits.length <= 9 ? digits : digits.substring(digits.length - 9);
}
