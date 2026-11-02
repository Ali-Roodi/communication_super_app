import 'package:flutter/material.dart';

/// Asks for the next page when the scrollable under it nears its end.
///
/// It listens to [ScrollMetricsNotification] as well as scrolling, so a first
/// page too short to fill the viewport — nothing to scroll, no scroll event —
/// still pulls the next one instead of stranding the rest of the list.
/// [onLoadMore] may fire more than once per page; the caller's own in-flight
/// guard is what makes that harmless.
class InfiniteScroll extends StatelessWidget {
  const InfiniteScroll({
    super.key,
    required this.hasMore,
    required this.onLoadMore,
    required this.child,
    this.threshold = 400,
  });

  final bool hasMore;
  final VoidCallback onLoadMore;
  final Widget child;

  /// How close to the end, in pixels, the next page is asked for.
  final double threshold;

  bool _check(ScrollMetrics m) {
    if (hasMore && m.axis == Axis.vertical && m.extentAfter < threshold) {
      onLoadMore();
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    return NotificationListener<ScrollMetricsNotification>(
      onNotification: (n) => n.depth == 0 && _check(n.metrics),
      child: NotificationListener<ScrollUpdateNotification>(
        onNotification: (n) => n.depth == 0 && _check(n.metrics),
        child: child,
      ),
    );
  }
}

/// The row at the end of a list that still has pages to load.
class LoadMoreIndicator extends StatelessWidget {
  const LoadMoreIndicator({super.key});

  @override
  Widget build(BuildContext context) {
    return const Padding(
      padding: EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: SizedBox.square(
          dimension: 24,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      ),
    );
  }
}
