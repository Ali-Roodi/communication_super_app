import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import '../bloc/template_bloc.dart';
import '../bloc/template_event.dart';
import '../models/message_template_model.dart';

/// Create / edit a template («ایجاد قالب»).
///
/// A template is just a title plus a body, so the only real teaching this
/// screen does is the placeholder syntax: the chips insert `[...]` names at the
/// cursor and the footer names the form the current text would generate, so the
/// user can see what the template will ask for before saving it.
class TemplateEditorScreen extends StatefulWidget {
  /// Null = create new. Non-null = edit existing.
  final MessageTemplate? template;

  const TemplateEditorScreen({super.key, this.template});

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  late bool _useContactName;

  /// Placeholders offered as one-tap chips — the ones the fill screen gives a
  /// picker or a multi-line box to.
  static const _suggested = ['عنوان', 'تاریخ', 'زمان', 'مکان', 'توضیحات'];

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.template?.title ?? '');
    _bodyController = TextEditingController(text: widget.template?.body ?? '');
    _useContactName = widget.template?.useContactName ?? false;
    // The footer mirrors the body's placeholders as they are typed.
    _bodyController.addListener(_onBodyChanged);
  }

  @override
  void dispose() {
    _bodyController.removeListener(_onBodyChanged);
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _onBodyChanged() => setState(() {});

  /// Inserts `[name]` at the cursor (replacing any selection) and keeps the
  /// caret after it, so a placeholder can be dropped mid-sentence while typing.
  void _insertPlaceholder(String name) {
    final token = '[$name]';
    final value = _bodyController.value;
    final selection = value.selection;
    if (!selection.isValid) {
      _bodyController.text = '${value.text}$token';
      _bodyController.selection = TextSelection.collapsed(
        offset: _bodyController.text.length,
      );
      return;
    }
    final text = value.text.replaceRange(selection.start, selection.end, token);
    _bodyController.value = TextEditingValue(
      text: text,
      selection: TextSelection.collapsed(offset: selection.start + token.length),
    );
  }

  void _save() {
    final body = _bodyController.text.trim();
    if (body.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('متن قالب را وارد کنید')));
      return;
    }
    context.read<TemplateBloc>().add(
      SaveTemplate(
        id: widget.template?.id,
        title: _titleController.text,
        body: body,
        useContactName: _useContactName,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isEditing = widget.template != null;
    final fields = TemplateEngine.fieldsOf(_bodyController.text);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(isEditing ? 'ویرایش قالب' : 'ایجاد قالب'),
          actions: [
            Padding(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimensions.paddingSm,
                vertical: 8,
              ),
              child: FilledButton(onPressed: _save, child: const Text('ذخیره')),
            ),
          ],
        ),
        body: ListView(
          padding: const EdgeInsets.all(AppDimensions.paddingMd),
          children: [
            TextField(
              controller: _titleController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(labelText: 'عنوان قالب'),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _bodyController,
              minLines: 6,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: 'متن قالب',
                alignLabelWithHint: true,
              ),
            ),
            const SizedBox(height: AppDimensions.paddingSm),
            Text(
              'جای‌گذار اضافه کنید؛ هنگام استفاده از قالب، مقدار آن پرسیده می‌شود.',
              style: theme.textTheme.bodySmall?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
            const SizedBox(height: AppDimensions.paddingSm),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final name in _suggested)
                  ActionChip(
                    avatar: const Icon(Icons.add, size: 18),
                    label: Text(name),
                    onPressed: () => _insertPlaceholder(name),
                  ),
              ],
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('درج نام مخاطب'),
              subtitle: const Text('پیام با «<نام> عزیز» آغاز می‌شود'),
              value: _useContactName,
              onChanged: (v) => setState(() => _useContactName = v),
            ),
            if (fields.isNotEmpty) ...[
              const SizedBox(height: AppDimensions.paddingSm),
              Text(
                'فیلدهای این قالب: ${fields.map((f) => f.label).join('، ')}',
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
