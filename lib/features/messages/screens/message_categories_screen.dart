import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../bloc/draft_bloc.dart';
import '../bloc/draft_event.dart';
import '../bloc/draft_state.dart';
import '../models/message_category_model.dart';

/// Draft categories (Figma «دسته‌بندی‌ها»).
///
/// Shows the virtual «همه» / «بدون دسته‌بندی» rows plus user categories, each
/// with its draft count. Tapping a row filters the drafts list and pops back.
/// The ＋ FAB adds a category; long-press a user category to rename / delete.
class MessageCategoriesScreen extends StatelessWidget {
  const MessageCategoriesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('دسته‌بندی‌ها')),
        body: BlocBuilder<DraftBloc, DraftState>(
          builder: (context, state) {
            if (state is! DraftsLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            return ListView(
              padding: const EdgeInsets.symmetric(
                horizontal: AppDimensions.paddingMd,
                vertical: AppDimensions.paddingSm,
              ),
              children: [
                _CategoryCard(
                  label: 'همه',
                  count: state.totalCount,
                  selected:
                      state.filterCategoryId == null &&
                      !state.filterUncategorized,
                  onTap: () => _select(context, const LoadDrafts()),
                ),
                _CategoryCard(
                  label: 'بدون دسته‌بندی',
                  count: state.uncategorizedCount,
                  selected: state.filterUncategorized,
                  onTap: () =>
                      _select(context, const LoadDrafts(uncategorized: true)),
                ),
                for (final c in state.categories)
                  _CategoryCard(
                    label: c.name,
                    count: c.draftCount,
                    selected: state.filterCategoryId == c.id,
                    onTap: () => _select(context, LoadDrafts(categoryId: c.id)),
                    onLongPress: () => _categoryOptions(context, c),
                  ),
              ],
            );
          },
        ),
        floatingActionButton: FloatingActionButton(
          heroTag: 'category_fab',
          onPressed: () => _addCategory(context),
          tooltip: 'افزودن دسته‌بندی',
          child: const Icon(Icons.add),
        ),
      ),
    );
  }

  void _select(BuildContext context, LoadDrafts event) {
    context.read<DraftBloc>().add(event);
    Navigator.of(context).pop();
  }

  Future<void> _addCategory(BuildContext context) async {
    final name = await _nameDialog(context, title: 'دسته‌بندی جدید');
    if (name != null && name.trim().isNotEmpty && context.mounted) {
      context.read<DraftBloc>().add(AddCategory(name.trim()));
    }
  }

  void _categoryOptions(BuildContext context, MessageCategory category) {
    final bloc = context.read<DraftBloc>();
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('تغییر نام'),
                onTap: () async {
                  Navigator.pop(sheetCtx);
                  final name = await _nameDialog(
                    context,
                    title: 'تغییر نام دسته‌بندی',
                    initial: category.name,
                  );
                  if (name != null && name.trim().isNotEmpty) {
                    bloc.add(RenameCategory(category.id, name.trim()));
                  }
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'حذف',
                  style: TextStyle(color: AppColors.danger),
                ),
                subtitle: const Text(
                  'پیش‌نویس‌ها به «بدون دسته‌بندی» منتقل می‌شوند',
                ),
                onTap: () {
                  bloc.add(DeleteCategory(category.id));
                  Navigator.pop(sheetCtx);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _nameDialog(
    BuildContext context, {
    required String title,
    String? initial,
  }) {
    final controller = TextEditingController(text: initial ?? '');
    return showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(title),
          content: TextField(
            controller: controller,
            autofocus: true,
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
  }
}

class _CategoryCard extends StatelessWidget {
  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _CategoryCard({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.listItemGap),
      child: Material(
        color: selected
            ? AppColors.accent.withValues(alpha: 0.12)
            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          onLongPress: onLongPress,
          child: Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: AppDimensions.paddingMd,
              vertical: 18,
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                      color: selected
                          ? AppColors.accent
                          : theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                ),
                Text(
                  PersianUtils.toPersianNumber('$count'),
                  style: theme.textTheme.bodyMedium,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
