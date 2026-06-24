import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import '../bloc/draft_bloc.dart';
import '../bloc/draft_event.dart';
import '../bloc/draft_state.dart';
import '../models/draft_model.dart';
import '../models/message_category_model.dart';

/// Create / edit a draft (Figma «ایجاد پیش‌نویس»).
///
/// Header: ✕ · title · «ذخیره» pill. Body: category dropdown, an optional
/// title field (not sent with the message), and the message text area.
class DraftEditorScreen extends StatefulWidget {
  /// Null = create new. Non-null = edit existing.
  final Draft? draft;

  /// Pre-selected category for a new draft (e.g. when created from a category).
  final String? initialCategoryId;

  const DraftEditorScreen({super.key, this.draft, this.initialCategoryId});

  @override
  State<DraftEditorScreen> createState() => _DraftEditorScreenState();
}

class _DraftEditorScreenState extends State<DraftEditorScreen> {
  late final TextEditingController _titleController;
  late final TextEditingController _bodyController;
  String? _categoryId;

  @override
  void initState() {
    super.initState();
    _titleController = TextEditingController(text: widget.draft?.title ?? '');
    _bodyController = TextEditingController(text: widget.draft?.body ?? '');
    _categoryId = widget.draft?.categoryId ?? widget.initialCategoryId;
  }

  @override
  void dispose() {
    _titleController.dispose();
    _bodyController.dispose();
    super.dispose();
  }

  void _save() {
    final body = _bodyController.text.trim();
    if (body.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('متن پیش‌نویس را وارد کنید')),
      );
      return;
    }
    context.read<DraftBloc>().add(
      SaveDraft(
        id: widget.draft?.id,
        title: _titleController.text,
        body: body,
        categoryId: _categoryId,
      ),
    );
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final isEditing = widget.draft != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => Navigator.of(context).pop(),
          ),
          title: Text(isEditing ? 'ویرایش پیش‌نویس' : 'ایجاد پیش‌نویس'),
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
            _CategoryDropdown(
              value: _categoryId,
              onChanged: (v) => setState(() => _categoryId = v),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _titleController,
              textInputAction: TextInputAction.next,
              decoration: const InputDecoration(
                labelText: 'عنوان (همراه پیام ارسال نمی‌شود)',
              ),
            ),
            const SizedBox(height: AppDimensions.paddingMd),
            TextField(
              controller: _bodyController,
              minLines: 6,
              maxLines: 14,
              decoration: const InputDecoration(
                labelText: 'متن',
                alignLabelWithHint: true,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Category picker dropdown — reads categories from [DraftBloc] state.
class _CategoryDropdown extends StatelessWidget {
  final String? value;
  final ValueChanged<String?> onChanged;

  const _CategoryDropdown({required this.value, required this.onChanged});

  @override
  Widget build(BuildContext context) {
    final categories = context.select<DraftBloc, List<MessageCategory>>(
      (b) => b.state is DraftsLoaded
          ? (b.state as DraftsLoaded).categories
          : const [],
    );
    // Guard against a stale value (category deleted while editing).
    final safeValue = categories.any((c) => c.id == value) ? value : null;

    return DropdownButtonFormField<String?>(
      initialValue: safeValue,
      isExpanded: true,
      decoration: const InputDecoration(labelText: 'دسته‌بندی'),
      items: [
        const DropdownMenuItem<String?>(
          value: null,
          child: Text('بدون دسته‌بندی'),
        ),
        for (final c in categories)
          DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
      ],
      onChanged: onChanged,
    );
  }
}
