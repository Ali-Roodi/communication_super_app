import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/selection_app_bar.dart';
import '../bloc/draft_bloc.dart';
import '../bloc/draft_event.dart';
import '../bloc/draft_state.dart';
import '../models/message_category_model.dart';
import 'widgets/category_name_dialog.dart';

/// Draft categories («دسته‌بندی‌ها»).
///
/// The page plane carries a single rounded sheet of pill rows — «همه» and
/// «بدون دسته‌بندی» first (virtual rows backed by counts, not by table rows),
/// then the user's categories, pinned ones on top. Tapping a row filters the
/// drafts grid and pops back.
///
/// Long-press starts **multi-select** rather than opening a per-row sheet, the
/// same gesture the inbox and the contacts list use: the header swaps for a
/// contextual bar carrying سنجاق / تغییر نام / حذف / انتخاب همه. «تغییر نام»
/// only makes sense on a single row, so it is hidden while more are selected.
class MessageCategoriesScreen extends StatefulWidget {
  const MessageCategoriesScreen({super.key});

  @override
  State<MessageCategoriesScreen> createState() =>
      _MessageCategoriesScreenState();
}

class _MessageCategoriesScreenState extends State<MessageCategoriesScreen> {
  /// Ids of the selected *user* categories. The virtual rows can never be in
  /// here — they have no row to rename, delete or pin.
  final Set<String> _selected = {};

  bool get _selectionMode => _selected.isNotEmpty;

  void _toggle(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  /// Drops ids that no longer exist (their category was just deleted), so the
  /// bar cannot linger over a selection that is gone.
  Set<String> _liveSelection(List<MessageCategory> categories) {
    final live = {for (final c in categories) c.id};
    return _selected.where(live.contains).toSet();
  }

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
                title: const Text('دسته‌بندی‌ها'),
                backgroundColor: scheme.pageBackground,
                surfaceTintColor: Colors.transparent,
              ),
        body: BlocBuilder<DraftBloc, DraftState>(
          builder: (context, state) {
            if (state is! DraftsLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            // Re-sync after a delete removed selected rows underneath us.
            final live = _liveSelection(state.categories);
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

            return _sheet(
              scheme,
              children: [
                _CategoryRow(
                  label: 'همه',
                  count: state.totalCount,
                  active:
                      state.filterCategoryId == null &&
                      !state.filterUncategorized,
                  onTap: () => _applyFilter(context, const LoadDrafts()),
                ),
                _CategoryRow(
                  label: 'بدون دسته‌بندی',
                  count: state.uncategorizedCount,
                  active: state.filterUncategorized,
                  onTap: () => _applyFilter(
                    context,
                    const LoadDrafts(uncategorized: true),
                  ),
                ),
                for (final c in state.categories)
                  _CategoryRow(
                    label: c.name,
                    count: c.draftCount,
                    pinned: c.isPinned,
                    active: state.filterCategoryId == c.id,
                    selectionMode: _selectionMode,
                    selected: _selected.contains(c.id),
                    onTap: () {
                      if (_selectionMode) {
                        _toggle(c.id);
                      } else {
                        _applyFilter(context, LoadDrafts(categoryId: c.id));
                      }
                    },
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      _toggle(c.id);
                    },
                  ),
              ],
            );
          },
        ),
        floatingActionButton: _selectionMode
            ? null
            : FloatingActionButton(
                heroTag: 'category_fab',
                onPressed: () => _addCategory(context),
                tooltip: 'افزودن دسته‌بندی',
                child: const Icon(Icons.add),
              ),
      ),
    );
  }

  /// The rounded plane every row sits on — the same «sheet on the page» shape
  /// the inbox and the settings groups use.
  Widget _sheet(ColorScheme scheme, {required List<Widget> children}) {
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.cardSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: ListView(
        padding: const EdgeInsets.fromLTRB(12, 16, 12, 96),
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: 8),
            children[i],
          ],
        ],
      ),
    );
  }

  List<Widget> _selectionActions(BuildContext context) {
    final state = context.read<DraftBloc>().state;
    final all = state is DraftsLoaded
        ? state.categories
        : const <MessageCategory>[];
    final chosen = all.where((c) => _selected.contains(c.id)).toList();
    final single = chosen.length == 1 ? chosen.first : null;

    return [
      IconButton(
        icon: const Icon(Icons.push_pin_outlined),
        tooltip: 'سنجاق',
        onPressed: chosen.isEmpty ? null : () => _pinSelected(context, chosen),
      ),
      if (single != null)
        IconButton(
          icon: const Icon(Icons.edit_outlined),
          tooltip: 'تغییر نام',
          onPressed: () => _renameCategory(context, single),
        ),
      IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: chosen.isEmpty
            ? null
            : () => _confirmDelete(context, chosen),
      ),
      IconButton(
        icon: const Icon(Icons.checklist),
        tooltip: 'انتخاب همه',
        onPressed: () => setState(() {
          _selected
            ..clear()
            ..addAll(all.map((c) => c.id));
        }),
      ),
    ];
  }

  /// Pins the selection; if every chosen row is already pinned the action
  /// unpins instead — the mixed-selection convention the inbox uses.
  void _pinSelected(BuildContext context, List<MessageCategory> chosen) {
    final pin = chosen.any((c) => !c.isPinned);
    context.read<DraftBloc>().add(
      PinCategories(chosen.map((c) => c.id).toList(), pin: pin),
    );
    _clearSelection();
  }

  void _applyFilter(BuildContext context, LoadDrafts event) {
    context.read<DraftBloc>().add(event);
    Navigator.of(context).pop();
  }

  Future<void> _addCategory(BuildContext context) async {
    final bloc = context.read<DraftBloc>();
    final name = await showCategoryNameDialog(context, title: 'دسته‌بندی جدید');
    if (name != null) bloc.add(AddCategory(name));
  }

  Future<void> _renameCategory(
    BuildContext context,
    MessageCategory category,
  ) async {
    final bloc = context.read<DraftBloc>();
    final name = await showCategoryNameDialog(
      context,
      title: 'تغییر نام دسته‌بندی',
      initial: category.name,
    );
    if (name != null) bloc.add(RenameCategory(category.id, name));
    _clearSelection();
  }

  Future<void> _confirmDelete(
    BuildContext context,
    List<MessageCategory> chosen,
  ) async {
    final bloc = context.read<DraftBloc>();
    final count = PersianUtils.toPersianNumber('${chosen.length}');
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text(
            '$count دسته‌بندی حذف شود؟ '
            'پیش‌نویس‌های آن‌ها به «بدون دسته‌بندی» منتقل می‌شوند.',
          ),
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
    bloc.add(DeleteCategories(chosen.map((c) => c.id).toList()));
    _clearSelection();
  }
}

/// One pill row: name at the start, draft count at the end.
///
/// [active] marks the filter the drafts grid is currently showing; [selected]
/// is the multi-select state. They are different things and can be true at
/// once, so they use different surfaces (tonal fill vs. the selection tint).
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.label,
    required this.count,
    required this.onTap,
    this.active = false,
    this.pinned = false,
    this.selectionMode = false,
    this.selected = false,
    this.onLongPress,
  });

  final String label;
  final int count;
  final bool active;
  final bool pinned;
  final bool selectionMode;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fill = selected
        ? scheme.secondaryContainer
        : active
        ? scheme.primaryContainer
        : scheme.surfaceContainer;
    final fg = selected
        ? scheme.onSecondaryContainer
        : active
        ? scheme.onPrimaryContainer
        : scheme.onSurface;

    return Material(
      color: fill,
      borderRadius: BorderRadius.circular(28),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 18, 16, 18),
          child: Row(
            children: [
              if (pinned) ...[
                Icon(Icons.push_pin, size: 16, color: fg),
                const SizedBox(width: 8),
              ],
              Expanded(
                child: Text(
                  label,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                    color: fg,
                  ),
                ),
              ),
              const SizedBox(width: 12),
              if (selectionMode && onLongPress != null)
                SelectionCheck(selected: selected, size: 24)
              else
                Text(
                  PersianUtils.toPersianNumber('$count'),
                  style: TextStyle(fontSize: 14, color: fg),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
