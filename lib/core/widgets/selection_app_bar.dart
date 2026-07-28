import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../theme/surface_roles.dart';

/// The contextual header a screen swaps in while rows are multi-selected:
/// ✕ + the count on the leading side, the actions trailing.
///
/// Google Messages' inbox has its own **sliver** version of this bar
/// (`MessagesSelectionAppBar`) because that screen's header collapses; screens
/// with an ordinary [AppBar] share this one instead of each re-deriving the
/// same layout and colours.
class SelectionAppBar extends StatelessWidget implements PreferredSizeWidget {
  const SelectionAppBar({
    super.key,
    required this.selectedCount,
    required this.onClear,
    required this.actions,
  });

  final int selectedCount;
  final VoidCallback onClear;
  final List<Widget> actions;

  @override
  Size get preferredSize => const Size.fromHeight(kToolbarHeight);

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return AppBar(
      backgroundColor: scheme.pageBackground,
      surfaceTintColor: Colors.transparent,
      leading: IconButton(
        icon: const Icon(Icons.close),
        tooltip: 'لغو انتخاب',
        onPressed: onClear,
      ),
      title: Text(PersianUtils.toPersianNumber('$selectedCount')),
      actions: [...actions, const SizedBox(width: 4)],
    );
  }
}

/// The round selection indicator that replaces a row's leading slot (or hangs
/// off a card's corner) while a list is in multi-select.
///
/// Unselected it is a plain tonal disc, not an empty ring: that is what Google
/// Keep / Messages draw, and it keeps the row's height from shifting when the
/// check appears.
class SelectionCheck extends StatelessWidget {
  const SelectionCheck({super.key, required this.selected, this.size = 28});

  final bool selected;
  final double size;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: selected
            ? scheme.primaryContainer
            : scheme.surfaceContainerHighest,
        shape: BoxShape.circle,
      ),
      child: selected
          ? Icon(
              Icons.check,
              size: size * 0.6,
              color: scheme.onPrimaryContainer,
            )
          : null,
    );
  }
}
