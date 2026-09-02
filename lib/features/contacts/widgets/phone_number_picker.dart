import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';

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
                          backgroundColor:
                              theme.colorScheme.secondaryContainer,
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
