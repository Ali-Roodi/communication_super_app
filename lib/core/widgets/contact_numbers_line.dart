import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/highlighted_phone.dart';

/// The number line every contact row carries under the name.
///
/// A name alone does not identify a contact — an address book holds several
/// «علی», and picking the right one from a search result or a list means seeing
/// the number. Contact rows used to be name-only (the number lived on the
/// detail page), which made those rows indistinguishable.
///
/// When [matched] is set (a number search hit that number) it is shown alone
/// with the typed digits emphasised; otherwise every number of the contact is
/// listed, separated by «·», truncated to [maxNumbers] with a «+N» tail.
class ContactNumbersLine extends StatelessWidget {
  const ContactNumbersLine({
    super.key,
    required this.numbers,
    this.matched,
    this.query = '',
    this.style,
    this.maxNumbers = 2,
  });

  /// All of the contact's numbers, in address-book order.
  final List<String> numbers;

  /// The number a digit query matched, if any.
  final String? matched;

  /// The digits typed, used to emphasise the matching run of [matched].
  final String query;

  final TextStyle? style;

  /// How many numbers are spelled out before the rest collapse into «+N».
  final int maxNumbers;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final effective =
        style ?? TextStyle(fontSize: 13, color: scheme.onSurfaceVariant);

    // Aligned to the ambient direction's start — under the name, not across the
    // row. An enclosing `Directionality(ltr)` (which the numbers do not need:
    // [PersianUtils.displayPhone] already wraps them in an LTR embedding) makes
    // the line align *left* inside the full-width subtitle box, which is why
    // the number sat away from the name it belongs to.
    final hit = matched;
    if (hit != null && hit.isNotEmpty) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: HighlightedPhone(number: hit, query: query, style: effective),
      );
    }

    final shown = numbers.where((n) => n.isNotEmpty).toList();
    if (shown.isEmpty) return const SizedBox.shrink();

    final visible = shown.take(maxNumbers).map(PersianUtils.displayPhone);
    final overflow = shown.length - maxNumbers;
    final text = [
      visible.join(' · '),
      if (overflow > 0) '+${PersianUtils.toPersianNumber('$overflow')}',
    ].join(' ');

    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Text(
        text,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: effective,
      ),
    );
  }
}
