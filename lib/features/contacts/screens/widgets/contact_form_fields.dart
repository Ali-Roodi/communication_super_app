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
