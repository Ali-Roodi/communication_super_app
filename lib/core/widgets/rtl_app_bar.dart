import 'package:flutter/material.dart';

class RtlAppBar extends StatelessWidget implements PreferredSizeWidget {
  final String? title;
  final Widget? titleWidget;
  final List<Widget>? actions;
  final Widget? leading;
  final bool automaticallyImplyLeading;
  final PreferredSizeWidget? bottom;
  final bool showDrawer;
  final bool showSearch;
  final bool showLock;
  final VoidCallback? onSearchPressed;
  final VoidCallback? onLockPressed;

  const RtlAppBar({
    super.key,
    this.title,
    this.titleWidget,
    this.actions,
    this.leading,
    this.automaticallyImplyLeading = true,
    this.bottom,
    this.showDrawer = false,
    this.showSearch = false,
    this.showLock = false,
    this.onSearchPressed,
    this.onLockPressed,
  }) : assert(
         title == null || titleWidget == null,
         'Cannot provide both title and titleWidget',
       );

  @override
  Widget build(BuildContext context) {
    // Build the actions list
    final List<Widget> appBarActions = [];

    if (showSearch && onSearchPressed != null) {
      appBarActions.add(
        IconButton(icon: const Icon(Icons.search), onPressed: onSearchPressed),
      );
    }

    if (showLock && onLockPressed != null) {
      appBarActions.add(
        IconButton(
          icon: const Icon(Icons.lock_outline),
          onPressed: onLockPressed,
        ),
      );
    }

    // Add any custom actions if provided
    if (actions != null) {
      appBarActions.addAll(actions!);
    }

    return Directionality(
      textDirection: TextDirection.rtl,
      child: AppBar(
        title: titleWidget ?? (title != null ? Text(title!) : null),
        actions: appBarActions.isNotEmpty ? appBarActions : null,
        leading:
            leading ??
            (showDrawer
                ? Builder(
                    builder: (context) => IconButton(
                      icon: const Icon(Icons.menu),
                      onPressed: () {
                        Scaffold.of(context).openDrawer();
                      },
                    ),
                  )
                : (automaticallyImplyLeading ? null : const SizedBox.shrink())),
        automaticallyImplyLeading: !showDrawer && automaticallyImplyLeading,
        bottom: bottom,
      ),
    );
  }

  @override
  Size get preferredSize {
    return AppBar().preferredSize;
  }
}
