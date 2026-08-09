import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/selection_app_bar.dart';
import 'package:communication_super_app/core/widgets/two_column_board.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import '../bloc/draft_bloc.dart';
import '../bloc/draft_event.dart';
import '../bloc/draft_state.dart';
import '../models/draft_model.dart';
import 'draft_editor_screen.dart';
import 'message_categories_screen.dart';

/// Drafts («پیش‌نویس‌ها») — a two-column note board on a rounded sheet, with the
/// category filter as chips across the top.
///
/// The staggered layout is deliberate: a draft is a block of text of unknown
/// length, and a single-column list of them wastes half the screen on the short
/// ones. Cards alternate between the two columns, each column a lazily-built
/// sliver (see [_DraftBoard]).
///
/// When [pickMode] is true the screen is a picker: tapping a draft pops with
/// its body instead of opening the editor, and multi-select is off — there is
/// nothing to act on in bulk while choosing one draft to insert.
class DraftsListScreen extends StatefulWidget {
  final bool pickMode;

  const DraftsListScreen({super.key, this.pickMode = false});

  @override
  State<DraftsListScreen> createState() => _DraftsListScreenState();
}

class _DraftsListScreenState extends State<DraftsListScreen> {
  bool get pickMode => widget.pickMode;

  final Set<String> _selected = {};

  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    // Load drafts once when the screen opens (keeps any active category filter).
    final state = context.read<DraftBloc>().state;
    if (state is! DraftsLoaded) {
      context.read<DraftBloc>().add(const LoadDrafts());
    }
  }

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: scheme.pageBackground,
        appBar: _selectionMode
            ? SelectionAppBar(
                selectedCount: _selected.length,
                onClear: _clearSelection,
                actions: _selectionActions(context),
              )
            : AppBar(
                title: Text(pickMode ? 'انتخاب پیش‌نویس' : 'پیش‌نویس‌ها'),
                backgroundColor: scheme.pageBackground,
                surfaceTintColor: Colors.transparent,
                actions: [
                  IconButton(
                    icon: const Icon(Icons.folder_outlined),
                    tooltip: 'دسته‌بندی‌ها',
                    onPressed: () => _openCategories(context),
                  ),
                  const SizedBox(width: 4),
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
            if (state is! DraftsLoaded) return const SizedBox.shrink();

            // A draft may have been deleted or filtered out from under the
            // selection; never let the bar count rows that are gone.
            final visible = {for (final d in state.drafts) d.id};
            final live = _selected.where(visible.contains).toSet();
            if (live.length != _selected.length) {
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (mounted) {
                  setState(() {
                    _selected
                      ..clear()
                      ..addAll(live);
                  });
                }
              });
            }

            return Container(
              decoration: BoxDecoration(
                color: scheme.cardSurface,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(28),
                ),
              ),
              clipBehavior: Clip.antiAlias,
              child: CustomScrollView(
                slivers: [
                  SliverToBoxAdapter(
                    child: _CategoryChips(
                      state: state,
                      onSelected: (event) =>
                          context.read<DraftBloc>().add(event),
                    ),
                  ),
                  if (state.drafts.isEmpty)
                    SliverFillRemaining(
                      hasScrollBody: false,
                      child: EmptyState(
                        icon: Icons.edit_note_outlined,
                        title: 'پیش‌نویسی وجود ندارد',
                        subtitle:
                            'پیش‌نویس‌های ذخیره‌شده اینجا نمایش داده می‌شوند',
                      ),
                    )
                  else ...[
                    const SliverToBoxAdapter(child: SizedBox(height: 4)),
                    _DraftBoard(
                      drafts: state.drafts,
                      selected: _selected,
                      selectionMode: _selectionMode,
                      onTap: (d) => _onDraftTap(context, d),
                      onLongPress: pickMode
                          ? null
                          : (d) {
                              HapticFeedback.mediumImpact();
                              _toggle(d.id);
                            },
                    ),
                  ],
                  const SliverToBoxAdapter(child: SizedBox(height: 96)),
                ],
              ),
            );
          },
        ),
        // Shown in pick mode too, so a draft can be created on the spot while
        // choosing one to insert into a message.
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                heroTag: 'drafts_fab',
                tooltip: 'پیش‌نویس جدید',
                onPressed: () => _newDraft(context),
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  // ── Selection bar ─────────────────────────────────────────────────────────

  List<Widget> _selectionActions(BuildContext context) {
    final state = context.read<DraftBloc>().state;
    final all = state is DraftsLoaded ? state.drafts : const <Draft>[];
    final chosen = all.where((d) => _selected.contains(d.id)).toList();

    return [
      IconButton(
        icon: const Icon(Icons.push_pin_outlined),
        tooltip: 'سنجاق',
        onPressed: chosen.isEmpty ? null : () => _pinSelected(context, chosen),
      ),
      IconButton(
        icon: const Icon(Icons.drive_file_move_outline),
        tooltip: 'انتقال به دسته‌بندی',
        onPressed: chosen.isEmpty ? null : () => _moveSelected(context),
      ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: chosen.isEmpty ? null : () => _confirmDelete(context, chosen),
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: 'انتخاب همه',
        onPressed: () => setState(() {
          _selected
            ..clear()
            ..addAll(all.map((d) => d.id));
        }),
      ),
    ];
  }

  /// Pins the selection; if every chosen draft is already pinned the action
  /// unpins instead — the mixed-selection convention the inbox uses.
  void _pinSelected(BuildContext context, List<Draft> chosen) {
    final pin = chosen.any((d) => !d.isPinned);
    context.read<DraftBloc>().add(
      PinDrafts(chosen.map((d) => d.id).toList(), pin: pin),
    );
    _clearSelection();
  }

  Future<void> _moveSelected(BuildContext context) async {
    final bloc = context.read<DraftBloc>();
    final state = bloc.state;
    if (state is! DraftsLoaded) return;
    final ids = _selected.toList();

    final target = await showModalBottomSheet<({String? id})>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 4, 24, 8),
                  child: Text(
                    'انتقال به دسته‌بندی',
                    style: Theme.of(sheetCtx).textTheme.titleMedium,
                  ),
                ),
                ListTile(
                  leading: const Icon(Icons.folder_off_outlined),
                  title: const Text('بدون دسته‌بندی'),
                  onTap: () => Navigator.pop(sheetCtx, (id: null)),
                ),
                for (final c in state.categories)
                  ListTile(
                    leading: const Icon(Icons.folder_outlined),
                    title: Text(c.name),
                    trailing: Text(
                      PersianUtils.toPersianNumber('${c.draftCount}'),
                    ),
                    onTap: () => Navigator.pop(sheetCtx, (id: c.id)),
                  ),
                const SizedBox(height: 8),
              ],
            ),
          ),
        ),
      ),
    );
    if (target == null) return;
    bloc.add(MoveDraftsToCategory(ids, target.id));
    _clearSelection();
  }

  Future<void> _confirmDelete(BuildContext context, List<Draft> chosen) async {
    final bloc = context.read<DraftBloc>();
    final count = PersianUtils.toPersianNumber('${chosen.length}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text('$count پیش‌نویس حذف شود؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'حذف',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    final removed = List<Draft>.from(chosen);
    bloc.add(DeleteDrafts(removed.map((d) => d.id).toList()));
    _clearSelection();
    if (!context.mounted) return;
    showUndoSnack(
      context,
      message: '$count پیش‌نویس حذف شد',
      // Re-saving restores the content and its category under a fresh id; a
      // pinned draft comes back unpinned, which is the honest outcome of "the
      // row is gone" rather than a half-restored one.
      onUndo: () {
        for (final d in removed) {
          bloc.add(
            SaveDraft(title: d.title, body: d.body, categoryId: d.categoryId),
          );
        }
      },
    );
  }

  // ── Navigation ────────────────────────────────────────────────────────────

  void _openCategories(BuildContext context) {
    final bloc = context.read<DraftBloc>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: const MessageCategoriesScreen(),
        ),
      ),
    );
  }

  void _newDraft(BuildContext context) {
    final bloc = context.read<DraftBloc>();
    final state = bloc.state;
    final categoryId = state is DraftsLoaded ? state.filterCategoryId : null;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: DraftEditorScreen(initialCategoryId: categoryId),
        ),
      ),
    );
  }

  void _onDraftTap(BuildContext context, Draft draft) {
    if (_selectionMode) {
      _toggle(draft.id);
      return;
    }
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
}

// ── Category filter chips ────────────────────────────────────────────────────

/// «همه» / «بدون دسته‌بندی» / one chip per category, scrolling horizontally.
///
/// The chips replaced the old "دسته‌بندی: x" status chip, which only *reported*
/// the filter — switching it meant a round trip through the categories screen.
class _CategoryChips extends StatelessWidget {
  const _CategoryChips({required this.state, required this.onSelected});

  final DraftsLoaded state;
  final ValueChanged<LoadDrafts> onSelected;

  @override
  Widget build(BuildContext context) {
    final all = state.filterCategoryId == null && !state.filterUncategorized;
    return SizedBox(
      height: 56,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        children: [
          _chip(
            label: 'همه',
            selected: all,
            onTap: () => onSelected(const LoadDrafts()),
          ),
          _chip(
            label: 'بدون دسته‌بندی',
            selected: state.filterUncategorized,
            onTap: () => onSelected(const LoadDrafts(uncategorized: true)),
          ),
          for (final c in state.categories)
            _chip(
              label: c.name,
              selected: state.filterCategoryId == c.id,
              onTap: () => onSelected(LoadDrafts(categoryId: c.id)),
            ),
        ],
      ),
    );
  }

  Widget _chip({
    required String label,
    required bool selected,
    required VoidCallback onTap,
  }) {
    return Padding(
      padding: const EdgeInsetsDirectional.only(end: 8),
      child: ChoiceChip(
        label: Text(label),
        selected: selected,
        showCheckmark: false,
        onSelected: (_) => onTap(),
      ),
    );
  }
}

// ── The board ────────────────────────────────────────────────────────────────

/// The drafts board — [SliverTwoColumnBoard] dealing [_DraftCard]s.
class _DraftBoard extends StatelessWidget {
  const _DraftBoard({
    required this.drafts,
    required this.selected,
    required this.selectionMode,
    required this.onTap,
    this.onLongPress,
  });

  final List<Draft> drafts;
  final Set<String> selected;
  final bool selectionMode;
  final ValueChanged<Draft> onTap;
  final ValueChanged<Draft>? onLongPress;

  @override
  Widget build(BuildContext context) {
    return SliverTwoColumnBoard<Draft>(
      items: drafts,
      itemBuilder: (context, draft) => _DraftCard(
        draft: draft,
        selectionMode: selectionMode,
        selected: selected.contains(draft.id),
        onTap: () => onTap(draft),
        onLongPress: onLongPress == null ? null : () => onLongPress!(draft),
      ),
    );
  }
}

class _DraftCard extends StatelessWidget {
  const _DraftCard({
    required this.draft,
    required this.selectionMode,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final Draft draft;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: selected ? scheme.secondaryContainer : scheme.surfaceContainer,
      borderRadius: BorderRadius.circular(20),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (draft.title != null && draft.title!.isNotEmpty)
                    Expanded(
                      child: Text(
                        draft.title!,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w700,
                          height: 1.3,
                          color: scheme.onSurface,
                        ),
                      ),
                    )
                  else
                    const Spacer(),
                  if (draft.isPinned && !selectionMode) ...[
                    const SizedBox(width: 6),
                    Icon(
                      Icons.push_pin,
                      size: 14,
                      color: scheme.onSurfaceVariant,
                    ),
                  ],
                  if (selectionMode) ...[
                    const SizedBox(width: 6),
                    SelectionCheck(selected: selected, size: 22),
                  ],
                ],
              ),
              if (draft.title != null && draft.title!.isNotEmpty)
                const SizedBox(height: 6),
              Text(
                draft.body,
                maxLines: 8,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
