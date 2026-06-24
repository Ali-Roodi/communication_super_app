import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import '../bloc/draft_bloc.dart';
import '../bloc/draft_event.dart';
import '../bloc/draft_state.dart';
import '../models/draft_model.dart';
import 'draft_editor_screen.dart';
import 'message_categories_screen.dart';

/// Drafts inbox (Figma «پیش‌نویس‌ها»). When [pickMode] is true the screen is
/// used as a picker (Figma «انتخاب پیش‌نویس»): tapping a draft pops with its
/// body string instead of opening the editor.
class DraftsListScreen extends StatefulWidget {
  final bool pickMode;

  const DraftsListScreen({super.key, this.pickMode = false});

  @override
  State<DraftsListScreen> createState() => _DraftsListScreenState();
}

class _DraftsListScreenState extends State<DraftsListScreen> {
  bool get pickMode => widget.pickMode;

  @override
  void initState() {
    super.initState();
    // Load drafts once when the screen opens (keeps any active category filter).
    final state = context.read<DraftBloc>().state;
    if (state is! DraftsLoaded) {
      context.read<DraftBloc>().add(const LoadDrafts());
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          title: Text(pickMode ? 'انتخاب پیش‌نویس' : 'پیش‌نویس‌ها'),
          actions: [
            IconButton(
              icon: const Icon(Icons.folder_outlined),
              tooltip: 'دسته‌بندی‌ها',
              onPressed: () {
                final bloc = context.read<DraftBloc>();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => BlocProvider.value(
                      value: bloc,
                      child: const MessageCategoriesScreen(),
                    ),
                  ),
                );
              },
            ),
          ],
        ),
        body: BlocBuilder<DraftBloc, DraftState>(
          builder: (context, state) {
            if (state is DraftLoading || state is DraftInitial) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is DraftError) {
              return Center(child: Text('خطا: ${state.message}'));
            }
            if (state is DraftsLoaded) {
              return Column(
                children: [
                  if (_filterLabel(state) != null)
                    _FilterChip(label: _filterLabel(state)!),
                  Expanded(
                    child: state.drafts.isEmpty
                        ? _emptyState(context)
                        : ListView.builder(
                            padding: const EdgeInsets.fromLTRB(
                              AppDimensions.paddingMd,
                              AppDimensions.paddingSm,
                              AppDimensions.paddingMd,
                              96,
                            ),
                            itemCount: state.drafts.length,
                            itemBuilder: (_, i) => _DraftCard(
                              draft: state.drafts[i],
                              onTap: () =>
                                  _onDraftTap(context, state.drafts[i]),
                              onDelete: pickMode
                                  ? null
                                  : () => context.read<DraftBloc>().add(
                                      DeleteDraft(state.drafts[i].id),
                                    ),
                            ),
                          ),
                  ),
                ],
              );
            }
            return const SizedBox.shrink();
          },
        ),
        floatingActionButton: pickMode
            ? null
            : FloatingActionButton(
                heroTag: 'drafts_fab',
                tooltip: 'پیش‌نویس جدید',
                onPressed: () {
                  final bloc = context.read<DraftBloc>();
                  final state = bloc.state;
                  final categoryId = state is DraftsLoaded
                      ? state.filterCategoryId
                      : null;
                  Navigator.of(context).push(
                    MaterialPageRoute(
                      builder: (_) => BlocProvider.value(
                        value: bloc,
                        child: DraftEditorScreen(initialCategoryId: categoryId),
                      ),
                    ),
                  );
                },
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  String? _filterLabel(DraftsLoaded state) {
    if (state.filterUncategorized) return 'بدون دسته‌بندی';
    if (state.filterCategoryId != null) {
      final match = state.categories
          .where((c) => c.id == state.filterCategoryId)
          .toList();
      return match.isNotEmpty ? match.first.name : null;
    }
    return null;
  }

  void _onDraftTap(BuildContext context, Draft draft) {
    if (pickMode) {
      Navigator.of(context).pop(draft.body);
      return;
    }
    final bloc = context.read<DraftBloc>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: DraftEditorScreen(draft: draft),
        ),
      ),
    );
  }

  Widget _emptyState(BuildContext context) {
    final theme = Theme.of(context);
    final dim = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.edit_note_outlined, size: 84, color: dim),
          const SizedBox(height: AppDimensions.paddingMd),
          Text('پیش‌نویسی وجود ندارد', style: theme.textTheme.titleMedium),
          const SizedBox(height: AppDimensions.paddingSm),
          Text(
            'پیش‌نویس‌های ذخیره‌شده اینجا نمایش داده می‌شوند',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: dim),
          ),
        ],
      ),
    );
  }
}

class _FilterChip extends StatelessWidget {
  final String label;
  const _FilterChip({required this.label});

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: AlignmentDirectional.centerStart,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(
          AppDimensions.paddingMd,
          AppDimensions.paddingSm,
          0,
          0,
        ),
        child: Chip(
          label: Text('دسته‌بندی: $label'),
          backgroundColor: AppColors.accent.withValues(alpha: 0.12),
          side: BorderSide.none,
        ),
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  final Draft draft;
  final VoidCallback onTap;
  final VoidCallback? onDelete;

  const _DraftCard({required this.draft, required this.onTap, this.onDelete});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: AppDimensions.listItemGap),
      child: Material(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(AppDimensions.paddingMd),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      if (draft.title != null) ...[
                        Text(
                          draft.title!,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        const SizedBox(height: 4),
                      ],
                      Text(
                        draft.body,
                        maxLines: 3,
                        overflow: TextOverflow.ellipsis,
                        style: theme.textTheme.bodyMedium,
                      ),
                    ],
                  ),
                ),
                if (onDelete != null)
                  IconButton(
                    icon: const Icon(Icons.delete_outline),
                    iconSize: 20,
                    color: theme.textTheme.bodyMedium?.color,
                    tooltip: 'حذف',
                    onPressed: onDelete,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
