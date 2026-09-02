import 'package:flutter/material.dart';

/// Fixed-width leading icon column shared by every contact form row so that the
/// icons line up in a single vertical rail and the fields start at the same x.
class ContactFieldLeading extends StatelessWidget {
  static const double width = 24;

  final IconData? icon;

  const ContactFieldLeading({super.key, required this.icon});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: icon == null
          ? null
          : Icon(
              icon,
              color: Theme.of(context).iconTheme.color?.withValues(alpha: 0.7),
            ),
    );
  }
}

/// A reusable underline text field with an optional leading icon, matching the
/// add/edit contact form layout (24px icon rail · 16px gap · expanded field).
///
/// Rows are ALWAYS icon-centred: multi-line fields start at one line
/// (`minLines: 1`) and only grow as the text wraps, so every row — نشانی,
/// شرکت, یادداشت included — has identical icon/text alignment at rest.
class ContactFormField extends StatelessWidget {
  final TextEditingController controller;
  final IconData? icon;
  final String label;
  final int maxLines;
  final TextInputType? keyboardType;
  final void Function(String)? onChanged;
  final String? Function(String?)? validator;

  const ContactFormField({
    super.key,
    required this.controller,
    required this.icon,
    required this.label,
    this.maxLines = 1,
    this.keyboardType,
    this.onChanged,
    this.validator,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ContactFieldLeading(icon: icon),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: controller,
              minLines: 1,
              maxLines: maxLines,
              keyboardType: keyboardType,
              onChanged: onChanged,
              validator: validator,
              decoration: InputDecoration(labelText: label),
            ),
          ),
        ],
      ),
    );
  }
}

/// A tappable value row (e.g. تاریخ تولد) rendered with [InputDecorator] so its
/// label, underline and vertical metrics are IDENTICAL to the text fields
/// around it — same 24px icon rail, same gap, same baseline.
class ContactValueField extends StatelessWidget {
  final IconData icon;
  final String label;
  final String value;
  final VoidCallback onTap;
  final VoidCallback? onClear;

  const ContactValueField({
    super.key,
    required this.icon,
    required this.label,
    required this.value,
    required this.onTap,
    this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: InkWell(
        onTap: onTap,
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            ContactFieldLeading(icon: icon),
            const SizedBox(width: 16),
            Expanded(
              child: InputDecorator(
                decoration: InputDecoration(labelText: label),
                child: Text(value),
              ),
            ),
            if (onClear != null)
              IconButton(
                icon: const Icon(Icons.close, size: 20),
                onPressed: onClear,
              ),
          ],
        ),
      ),
    );
  }
}

/// Leading-aligned "+ add another" text button used under the phone/email
/// sections of the contact form. Indented to line up with the field column.
class AddMoreButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const AddMoreButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Padding(
      // 16 (row padding) + 24 (icon rail) = start of the field column.
      padding: const EdgeInsets.only(right: 40, left: 16),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: onTap,
          icon: const Icon(Icons.add),
          label: Text(label),
        ),
      ),
    );
  }
}

/// The compact type selector («موبایل» / «منزل» / …) that sits at the trailing
/// edge of a phone or email row in the contact form.
///
/// A plain [DropdownButton] is the wrong control *here* for one measurable
/// reason: it sizes itself to its widest menu item («محل کار») and adds a
/// 24 dp arrow and the button's own padding on top, so on a 360 dp phone the
/// three trailing controls ate about 145 dp of a 288 dp row and the number
/// field — the only field the user actually types into — was left narrower
/// than the label floating above it. Google Contacts gives the value field the
/// width and keeps the type a small, quiet affordance; so does this.
///
/// The compaction is honest, not a squeeze: the label is `bodyMedium`, the
/// arrow is 18 dp, `isDense` removes the button's vertical padding, and the
/// whole thing is capped by [maxWidth] with the text ellipsised rather than
/// allowed to push the field. The menu itself is untouched — it still lists
/// every label at full size.
class CompactLabelDropdown<T> extends StatelessWidget {
  const CompactLabelDropdown({
    super.key,
    required this.value,
    required this.labels,
    required this.onChanged,
    this.maxWidth = 62,
  });

  final T value;
  final Map<T, String> labels;
  final ValueChanged<T> onChanged;
  final double maxWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ConstrainedBox(
      constraints: BoxConstraints(maxWidth: maxWidth),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<T>(
          value: value,
          isDense: true,
          isExpanded: true,
          borderRadius: BorderRadius.circular(12),
          icon: const Icon(Icons.arrow_drop_down, size: 16),
          iconSize: 16,
          style: theme.textTheme.labelMedium?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
          // The *selected* value is drawn by this builder, so the row can show
          // an ellipsised single line while the open menu keeps full labels.
          selectedItemBuilder: (context) => [
            for (final label in labels.values)
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelMedium?.copyWith(
                    color: theme.colorScheme.onSurfaceVariant,
                  ),
                ),
              ),
          ],
          items: [
            for (final entry in labels.entries)
              DropdownMenuItem(value: entry.key, child: Text(entry.value)),
          ],
          onChanged: (v) {
            if (v != null) onChanged(v);
          },
        ),
      ),
    );
  }
}

/// The ✕ that removes one phone/email row.
///
/// Sized down from the stock [IconButton]'s 48 dp square to 32 dp: two
/// trailing controls plus a 48 dp button is what left the number field too
/// narrow to read a full number in. 32 dp is the Material minimum for a
/// secondary affordance inside a dense form row, and the row itself is 56 dp
/// tall so the vertical target is unchanged.
class RemoveFieldButton extends StatelessWidget {
  const RemoveFieldButton({super.key, required this.onPressed, this.tooltip});

  /// Null disables the button (the last remaining phone row).
  final VoidCallback? onPressed;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.close, size: 18),
      tooltip: tooltip,
      onPressed: onPressed,
      padding: EdgeInsets.zero,
      visualDensity: VisualDensity.compact,
      constraints: const BoxConstraints.tightFor(width: 32, height: 32),
      splashRadius: 18,
    );
  }
}
