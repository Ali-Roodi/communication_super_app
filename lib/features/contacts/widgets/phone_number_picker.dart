import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';

/// Asks which of a contact's numbers to act on, the way Google Contacts does
/// when a contact has more than one.
///
/// Returns the chosen number, or null when the user dismissed the sheet. A
/// contact with a single number resolves immediately — never make the user
/// confirm a choice they don't have — and one with none returns null.
Future<String?> pickContactNumber(
  BuildContext context, {
  required List<String> numbers,
  required String title,
}) async {
  final usable = numbers.where((n) => n.trim().isNotEmpty).toList();
  if (usable.isEmpty) return null;
  if (usable.length == 1) return usable.first;

  return showModalBottomSheet<String>(
    context: context,
    showDragHandle: true,
    builder: (sheetCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 4, 24, 12),
              child: Text(
                title,
                style: Theme.of(sheetCtx).textTheme.titleMedium,
              ),
            ),
            for (final number in usable)
              ListTile(
                leading: const Icon(Icons.phone_outlined),
                title: Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    PersianUtils.displayPhone(number),
                    textAlign: TextAlign.right,
                  ),
                ),
                onTap: () => Navigator.pop(sheetCtx, number),
              ),
          ],
        ),
      ),
    ),
  );
}
