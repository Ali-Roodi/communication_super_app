import 'package:flutter/material.dart';
import '../theme/surface_roles.dart';

/// Building blocks shared by every redesigned screen, matching the shape
/// language Google Phone and Google Messages use:
///
/// * rows live inside **groups** — a run of cards with large outer corners,
///   barely-rounded seams and a 3 px gap between them,
/// * section titles are small, tinted labels floating on the page,
/// * the search field is a 56 px pill sitting on the page, not an app bar.
///
/// Everything here is RTL-agnostic: callers wrap their screen in a
/// [Directionality] as usual and these widgets mirror automatically.

// ── Section label ────────────────────────────────────────────────────────────

/// A small heading above a group («عمومی»، «قدیمی‌تر»، …).
///
/// Google tints these differently per app: settings-style headings are drawn in
/// the primary colour, while the list headings inside Contacts (alphabet
/// letters, «تنظیمات مخاطب») are plain grey. [tinted] picks between the two.
class SectionLabel extends StatelessWidget {
  final String text;
  final EdgeInsetsGeometry padding;
  final bool tinted;

  const SectionLabel(
    this.text, {
    super.key,
    this.padding = const EdgeInsets.fromLTRB(24, 20, 24, 10),
    this.tinted = true,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: padding,
      child: Text(
        text,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w600,
          color: tinted ? scheme.primary : scheme.onSurfaceVariant,
        ),
      ),
    );
  }
}

// ── Grouped rows ─────────────────────────────────────────────────────────────

/// Lays out [children] as one visual group: each child is placed on a card
/// whose corners follow [GroupRadius], separated by [GroupRadius.gap].
///
/// The children are *contents*, not cards — this widget supplies the surface,
/// so a row is written as plain padding + text.
class GroupedList extends StatelessWidget {
  final List<Widget> children;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const GroupedList({
    super.key,
    required this.children,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (children.isEmpty) return const SizedBox.shrink();
    final surface = color ?? Theme.of(context).colorScheme.cardSurface;
    return Padding(
      padding: padding,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (var i = 0; i < children.length; i++) ...[
            if (i > 0) const SizedBox(height: GroupRadius.gap),
            Material(
              color: surface,
              clipBehavior: Clip.antiAlias,
              borderRadius: GroupRadius.forIndex(i, children.length),
              child: children[i],
            ),
          ],
        ],
      ),
    );
  }
}

/// Lazy sliver twin of [GroupedList]: the same run of cards, but rows are built
/// on demand instead of all at once.
///
/// [GroupedList] materialises every child eagerly (it is a [Column]), which is
/// fine for a settings group and *not* fine for a list whose length follows the
/// address book — a search matching a few thousand contacts would build a few
/// thousand rows, each firing its own avatar lookup. Use this whenever the row
/// count is data-driven.
class SliverGroupedList extends StatelessWidget {
  final int itemCount;
  final IndexedWidgetBuilder itemBuilder;
  final EdgeInsetsGeometry padding;
  final Color? color;

  const SliverGroupedList({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.color,
  });

  @override
  Widget build(BuildContext context) {
    if (itemCount == 0) {
      return const SliverToBoxAdapter(child: SizedBox.shrink());
    }
    final surface = color ?? Theme.of(context).colorScheme.cardSurface;
    return SliverPadding(
      padding: padding,
      sliver: SliverList.builder(
        itemCount: itemCount,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : GroupRadius.gap),
          child: Material(
            color: surface,
            clipBehavior: Clip.antiAlias,
            borderRadius: GroupRadius.forIndex(i, itemCount),
            child: itemBuilder(context, i),
          ),
        ),
      ),
    );
  }
}

/// A single standalone card (a one-row group).
class GroupedCard extends StatelessWidget {
  final Widget child;
  final EdgeInsetsGeometry padding;
  final Color? color;
  final double radius;

  const GroupedCard({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 12),
    this.color,
    this.radius = GroupRadius.outer,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: padding,
      child: Material(
        color: color ?? Theme.of(context).colorScheme.cardSurface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(radius),
        child: child,
      ),
    );
  }
}

/// The standard settings row: optional leading icon, title, optional summary,
/// optional trailing widget (switch, value text, chevron).
class SettingsRow extends StatelessWidget {
  final IconData? icon;
  final String title;
  final String? summary;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool enabled;
  final Color? titleColor;

  const SettingsRow({
    super.key,
    this.icon,
    required this.title,
    this.summary,
    this.trailing,
    this.onTap,
    this.enabled = true,
    this.titleColor,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = enabled
        ? (titleColor ?? scheme.onSurface)
        : scheme.onSurface.withValues(alpha: 0.38);
    final dim = enabled
        ? scheme.onSurfaceVariant
        : scheme.onSurfaceVariant.withValues(alpha: 0.38);

    return InkWell(
      onTap: enabled ? onTap : null,
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 18, trailing != null ? 12 : 20, 18),
        child: Row(
          children: [
            if (icon != null) ...[
              Icon(icon, size: 24, color: dim),
              const SizedBox(width: 20),
            ],
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(fontSize: 16, color: fg, height: 1.3),
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 3),
                    Text(
                      summary!,
                      style: TextStyle(fontSize: 14, color: dim, height: 1.35),
                    ),
                  ],
                ],
              ),
            ),
            if (trailing != null) ...[const SizedBox(width: 12), trailing!],
          ],
        ),
      ),
    );
  }
}

/// A tonal action row — the «تماس تصویری / پیام / سابقه» rows Google Phone
/// reveals inside an expanded call card.
class TonalActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;
  final Color? foreground;

  const TonalActionRow({
    super.key,
    required this.icon,
    required this.label,
    this.onTap,
    this.foreground,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final fg = foreground ?? scheme.onSurface;
    return Material(
      color: scheme.tonalRow,
      clipBehavior: Clip.antiAlias,
      borderRadius: BorderRadius.circular(14),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 16),
          child: Row(
            children: [
              Icon(icon, size: 22, color: fg),
              const SizedBox(width: 18),
              Text(
                label,
                style: TextStyle(
                  fontSize: 16,
                  color: fg,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Search pill ──────────────────────────────────────────────────────────────

/// The 56 px search pill that sits at the top of Google Phone's home screen —
/// a tappable surface, not a real text field.
class SearchPill extends StatelessWidget {
  final String hint;
  final VoidCallback? onTap;
  final Widget? leading;
  final Widget? trailing;

  const SearchPill({
    super.key,
    required this.hint,
    this.onTap,
    this.leading,
    this.trailing,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
      child: Material(
        color: scheme.cardSurface,
        clipBehavior: Clip.antiAlias,
        borderRadius: BorderRadius.circular(28),
        child: InkWell(
          onTap: onTap,
          child: SizedBox(
            height: 56,
            child: Row(
              children: [
                const SizedBox(width: 8),
                leading ??
                    Icon(
                      Icons.search,
                      color: scheme.onSurfaceVariant,
                      size: 24,
                    ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hint,
                    style: TextStyle(
                      fontSize: 16,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
                const SizedBox(width: 8),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Filter chips ─────────────────────────────────────────────────────────────

/// Horizontally scrolling filter row («همه · بی‌پاسخ · مخاطبین · …»).
class FilterChipsRow<T> extends StatelessWidget {
  final Map<T, String> options;
  final T selected;
  final ValueChanged<T> onSelected;
  final EdgeInsetsGeometry padding;

  const FilterChipsRow({
    super.key,
    required this.options,
    required this.selected,
    required this.onSelected,
    this.padding = const EdgeInsets.fromLTRB(12, 0, 12, 8),
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: padding,
        children: [
          for (final entry in options.entries) ...[
            ChoiceChip(
              label: Text(entry.value),
              selected: entry.key == selected,
              onSelected: (_) => onSelected(entry.key),
            ),
            const SizedBox(width: 8),
          ],
        ],
      ),
    );
  }
}

// ── Empty state ──────────────────────────────────────────────────────────────

/// The centred icon + title + subtitle Google shows for an empty list.
class EmptyState extends StatelessWidget {
  final IconData icon;
  final String title;
  final String? subtitle;
  final Widget? action;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.action,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 40),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              width: 96,
              height: 96,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, size: 44, color: scheme.onSecondaryContainer),
            ),
            const SizedBox(height: 24),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 20,
                fontWeight: FontWeight.w500,
                color: scheme.onSurface,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 15,
                  height: 1.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
            if (action != null) ...[const SizedBox(height: 24), action!],
          ],
        ),
      ),
    );
  }
}
