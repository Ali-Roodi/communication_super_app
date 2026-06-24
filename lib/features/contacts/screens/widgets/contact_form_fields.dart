import 'package:flutter/material.dart';

/// A reusable underline text field with an optional leading icon, matching the
/// add/edit contact form layout (icon column · 16px gap · expanded field).
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 24,
            child: icon == null
                ? null
                : Padding(
                    padding: const EdgeInsets.only(top: 16),
                    child: Icon(icon),
                  ),
          ),
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
/// sections of the contact form.
class AddMoreButton extends StatelessWidget {
  final String label;
  final VoidCallback onTap;

  const AddMoreButton({super.key, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: TextButton.icon(
        onPressed: onTap,
        icon: const Icon(Icons.add),
        label: Text(label),
      ),
    );
  }
}
