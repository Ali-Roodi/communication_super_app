import 'package:flutter/material.dart';

/// Fixed-width leading icon column shared by every contact form row so that the
/// icons line up in a single vertical rail and the fields start at the same x.
///
/// Pass [topAligned] for multi-line rows so the icon sits on the first input
/// line instead of the vertical centre of the (tall) field.
class ContactFieldLeading extends StatelessWidget {
  static const double width = 24;

  final IconData? icon;
  final bool topAligned;

  const ContactFieldLeading({super.key, required this.icon, this.topAligned = false});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: icon == null
          ? null
          : Padding(
              // On multi-line rows the row is start-aligned, so nudge the icon
              // down to meet the first line of text.
              padding: EdgeInsets.only(top: topAligned ? 14 : 0),
              child: Icon(
                icon,
                color: Theme.of(context).iconTheme.color?.withValues(alpha: 0.7),
              ),
            ),
    );
  }
}

/// A reusable underline text field with an optional leading icon, matching the
/// add/edit contact form layout (24px icon rail · 16px gap · expanded field).
///
/// Single-line rows centre the icon against the field; multi-line rows align it
/// to the first line.
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
    final multiline = maxLines > 1;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Row(
        crossAxisAlignment:
            multiline ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          ContactFieldLeading(icon: icon, topAligned: multiline),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: controller,
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
