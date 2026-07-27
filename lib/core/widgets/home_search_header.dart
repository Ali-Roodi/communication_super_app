import 'package:flutter/material.dart';
import '../theme/surface_roles.dart';
import '../../features/search/screens/search_screen.dart';
import '../../features/settings/screens/settings_screen.dart';

/// The search pill that heads every home tab, mirroring Google Phone: a 56 px
/// rounded surface with the overflow menu on the leading side and the search
/// hint filling the rest. Tapping anywhere but the menu opens search.
///
/// It replaces the old shared [AppBar] — Google's home screens have no app bar
/// at all, the pill *is* the header.
class HomeSearchHeader extends StatelessWidget {
  final String hint;

  /// Extra entries appended to the overflow menu, keyed by their label.
  final Map<String, VoidCallback> extraMenuItems;

  const HomeSearchHeader({
    super.key,
    this.hint = 'جستجوی مخاطبین',
    this.extraMenuItems = const {},
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      bottom: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
        child: Material(
          color: scheme.cardSurface,
          clipBehavior: Clip.antiAlias,
          borderRadius: BorderRadius.circular(28),
          child: InkWell(
            onTap: () => Navigator.of(
              context,
            ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
            child: SizedBox(
              height: 56,
              child: Row(
                children: [
                  const SizedBox(width: 4),
                  PopupMenuButton<VoidCallback>(
                    icon: Icon(Icons.menu, color: scheme.onSurface),
                    tooltip: 'گزینه‌های بیشتر',
                    position: PopupMenuPosition.under,
                    onSelected: (action) => action(),
                    itemBuilder: (_) => [
                      for (final entry in extraMenuItems.entries)
                        PopupMenuItem<VoidCallback>(
                          value: entry.value,
                          child: Text(entry.key),
                        ),
                      PopupMenuItem<VoidCallback>(
                        value: () => Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        ),
                        child: const Text('تنظیمات'),
                      ),
                    ],
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      hint,
                      style: TextStyle(
                        fontSize: 16,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                  Icon(Icons.search, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 16),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
