import 'package:flutter/material.dart';

/// Name prompt shared by «دسته‌بندی جدید» and «تغییر نام دسته‌بندی».
///
/// Returns the trimmed name, or null when the user cancelled **or** left it
/// blank — callers can dispatch straight from the result without re-checking,
/// which is what kept the two call sites from drifting apart.
Future<String?> showCategoryNameDialog(
  BuildContext context, {
  required String title,
  String? initial,
}) async {
  // Owned by the function, so it has no `dispose` to be called from — the
  // controller is released once the dialog is gone. Without this every open of
  // «نام دسته‌بندی» leaked a controller and its listeners for the process.
  final controller = TextEditingController(text: initial ?? '');
  final name = await showDialog<String>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textInputAction: TextInputAction.done,
          decoration: const InputDecoration(hintText: 'نام دسته‌بندی'),
          onSubmitted: (v) => Navigator.pop(ctx, v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, controller.text),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    ),
  );
  controller.dispose();
  final trimmed = name?.trim();
  return (trimmed == null || trimmed.isEmpty) ? null : trimmed;
}
