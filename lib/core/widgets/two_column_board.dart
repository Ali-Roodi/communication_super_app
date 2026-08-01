import 'package:flutter/material.dart';

/// Two lazily-built columns side by side, cards dealt alternately between them
/// — the note board the drafts («پیش‌نویس‌ها») and templates («قالب‌های آماده»)
/// screens are drawn on.
///
/// A `SliverGrid` would force every card to the same height and a `Column` of
/// all items would build them all at once; [SliverCrossAxisGroup] keeps both
/// columns lazy while letting each card be exactly as tall as its text.
class SliverTwoColumnBoard<T> extends StatelessWidget {
  const SliverTwoColumnBoard({
    super.key,
    required this.items,
    required this.itemBuilder,
    this.outerGap = 16,
    this.innerGap = 6,
    this.cardGap = 12,
  });

  final List<T> items;
  final Widget Function(BuildContext context, T item) itemBuilder;

  /// Space between a card and the edge of the sheet.
  final double outerGap;

  /// Space between the two columns (half on each card).
  final double innerGap;

  /// Vertical space under each card.
  final double cardGap;

  @override
  Widget build(BuildContext context) {
    // `SliverCrossAxisGroup` places its children left-to-right and does NOT
    // mirror for an RTL Directionality, so the leading column is chosen here.
    // Without this the board deals the first card to the *left* and reads
    // backwards on a Persian screen.
    final rtl = Directionality.of(context) == TextDirection.rtl;
    final leading = rtl ? 1 : 0; // logical column drawn on the physical left
    return SliverCrossAxisGroup(
      slivers: [
        SliverCrossAxisExpanded(
          flex: 1,
          sliver: _column(
            leading,
            EdgeInsets.only(left: outerGap, right: innerGap),
          ),
        ),
        SliverCrossAxisExpanded(
          flex: 1,
          sliver: _column(
            1 - leading,
            EdgeInsets.only(left: innerGap, right: outerGap),
          ),
        ),
      ],
    );
  }

  /// Physical padding, not directional: the group already fixed the sides, and
  /// an `EdgeInsetsDirectional` here would mirror them back.
  Widget _column(int column, EdgeInsets padding) {
    final columnItems = [
      for (var i = column; i < items.length; i += 2) items[i],
    ];
    return SliverPadding(
      padding: padding,
      sliver: SliverList.builder(
        itemCount: columnItems.length,
        itemBuilder: (context, i) => Padding(
          padding: EdgeInsets.only(bottom: cardGap),
          child: itemBuilder(context, columnItems[i]),
        ),
      ),
    );
  }
}
