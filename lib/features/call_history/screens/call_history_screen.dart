import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/home_search_header.dart';
import '../bloc/call_log_bloc.dart';
import '../bloc/call_log_event.dart';
import '../bloc/call_log_state.dart';
import '../models/call_log_model.dart';
import 'widgets/call_log_tile.dart';

/// The recents tab — Google Phone's home screen.
///
/// Header pill · filter chips · day sections, each section a run of grouped
/// cards. A row expands **in place** (see [CallLogTile]); only one row is open
/// at a time, which is what keeps the list readable on a long history.
class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

enum _CallFilter { all, missed, contacts }

const Map<_CallFilter, String> _filterLabels = {
  _CallFilter.all: 'همه',
  _CallFilter.missed: 'بی‌پاسخ',
  _CallFilter.contacts: 'مخاطبین',
};

class _CallHistoryScreenState extends State<CallHistoryScreen> {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();
  _CallFilter _filter = _CallFilter.all;

  /// Id of the representative call whose card is currently expanded.
  String? _expandedId;

  bool _matchesFilter(CallLogModel log) {
    switch (_filter) {
      case _CallFilter.all:
        return true;
      case _CallFilter.missed:
        // "بی‌پاسخ" covers missed and rejected calls.
        return log.callType == CallType.missed ||
            log.callType == CallType.rejected;
      case _CallFilter.contacts:
        return log.contactName?.isNotEmpty == true;
    }
  }

  // Memoize the display item list (day headers + grouped rows) so grouping
  // only runs when the underlying data or the active filter changes, not on
  // every widget rebuild (expanding a row rebuilds the list).
  List<CallLogModel>? _lastSource;
  _CallFilter? _lastFilter;
  List<Object> _cachedItems = [];

  /// Flat list of display items: [String] day headers (امروز / دیروز /
  /// قدیمی‌تر) interleaved with [_CallGroup] rows carrying their position
  /// inside the section run, so each card can pick the right corner radii.
  List<Object> _getOrBuildItems(List<CallLogModel> source) {
    if (identical(_lastSource, source) && _lastFilter == _filter) {
      return _cachedItems;
    }
    _lastSource = source;
    _lastFilter = _filter;
    final filtered = source.where(_matchesFilter).toList();
    final groups = _groupCallLogs(filtered);

    final items = <Object>[];
    String? currentBucket;
    var runStart = 0; // index in `items` where the current run's first row sits
    for (final g in groups) {
      final bucket = _dayBucket(g.representative.timestamp);
      if (bucket != currentBucket) {
        _closeRun(items, runStart);
        currentBucket = bucket;
        items.add(bucket);
        runStart = items.length;
      }
      items.add(_Row(group: g, isFirst: items.length == runStart, isLast: true));
    }
    _closeRun(items, runStart);
    _cachedItems = items;
    return _cachedItems;
  }

  /// Marks every row of the run that started at [runStart] except the last one
  /// as "not last", so only the bottom card gets a large bottom radius.
  static void _closeRun(List<Object> items, int runStart) {
    for (var i = runStart; i < items.length - 1; i++) {
      final row = items[i] as _Row;
      items[i] = _Row(group: row.group, isFirst: row.isFirst, isLast: false);
    }
  }

  /// Persian day-bucket label for a timestamp.
  static String _dayBucket(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(day).inDays;
    if (diff <= 0) return 'امروز';
    if (diff == 1) return 'دیروز';
    return 'قدیمی‌تر';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasLoadedInitially) {
        _hasLoadedInitially = true;
        context.read<CallLogBloc>().add(const LoadCallLogs());
      }
    });
    _scrollController.addListener(_onScroll);
  }

  void _onScroll() {
    if (!mounted) return;
    final state = context.read<CallLogBloc>().state;
    if (state is! CallLogsLoaded || !state.hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      context.read<CallLogBloc>().add(const LoadMoreCallLogs());
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  // No lifecycle observer here on purpose: [MainNavigation] already dispatches
  // a silent `SyncCallLogs` on resume. This screen used to fire its own
  // `RefreshCallLogs` as well, so every return to the app ran the device sync
  // *twice* — and that one emits `CallLogLoading`, blanking the list behind a
  // spinner while it ran.

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        children: [
          HomeSearchHeader(
            extraMenuItems: {
              'پاک کردن سابقه تماس': () => _confirmClearHistory(context),
            },
          ),
          FilterChipsRow<_CallFilter>(
            options: _filterLabels,
            selected: _filter,
            onSelected: (f) {
              if (_filter != f) {
                setState(() {
                  _filter = f;
                  _expandedId = null;
                });
              }
            },
          ),
          Expanded(
            child: BlocBuilder<CallLogBloc, CallLogState>(
              builder: (context, state) {
                if (state is CallLogLoading) {
                  return const Center(child: CircularProgressIndicator());
                }
                if (state is CallLogError) {
                  return Center(child: Text('خطا: ${state.message}'));
                }
                if (state is! CallLogsLoaded) return const SizedBox.shrink();

                if (state.callLogs.isEmpty) {
                  return const EmptyState(
                    icon: Icons.call_outlined,
                    title: 'تماس اخیری وجود ندارد',
                    subtitle: 'تماس‌های ورودی و خروجی شما اینجا نمایش داده می‌شوند',
                  );
                }

                final items = _getOrBuildItems(state.callLogs);
                if (items.isEmpty) {
                  return EmptyState(
                    icon: _filter == _CallFilter.missed
                        ? Icons.call_missed
                        : Icons.person_outline,
                    title: _filter == _CallFilter.missed
                        ? 'تماس بی‌پاسخی نیست'
                        : 'تماسی با مخاطبین ذخیره‌شده نیست',
                  );
                }

                return RefreshIndicator(
                  onRefresh: () async =>
                      context.read<CallLogBloc>().add(const RefreshCallLogs()),
                  child: ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.only(bottom: 120),
                    itemCount: items.length + (state.hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (state.hasMore && index == items.length) {
                        return const Padding(
                          padding: EdgeInsets.all(16),
                          child: Center(child: CircularProgressIndicator()),
                        );
                      }
                      final item = items[index];
                      if (item is String) return SectionLabel(item);

                      final row = item as _Row;
                      final rep = row.group.representative;
                      return Padding(
                        padding: EdgeInsets.fromLTRB(
                          12,
                          row.isFirst ? 0 : GroupRadius.gap,
                          12,
                          0,
                        ),
                        child: CallLogTile(
                          log: rep,
                          count: row.group.count,
                          groupIds: row.group.ids,
                          groupLogs: row.group.logs,
                          expanded: _expandedId == rep.id,
                          onToggle: () => setState(
                            () => _expandedId = _expandedId == rep.id
                                ? null
                                : rep.id,
                          ),
                          radius: BorderRadius.vertical(
                            top: Radius.circular(
                              row.isFirst ? GroupRadius.outer : GroupRadius.inner,
                            ),
                            bottom: Radius.circular(
                              row.isLast ? GroupRadius.outer : GroupRadius.inner,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _confirmClearHistory(BuildContext context) async {
    final bloc = context.read<CallLogBloc>();
    final state = bloc.state;
    if (state is! CallLogsLoaded || state.callLogs.isEmpty) return;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('پاک کردن سابقه تماس'),
          content: const Text(
            'همه تماس‌های نمایش‌داده‌شده از گوشی حذف می‌شوند. این کار برگشت‌پذیر نیست.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(
                foregroundColor: Theme.of(ctx).colorScheme.error,
              ),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('پاک کردن'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true) {
      bloc.add(DeleteCallLogs([for (final l in state.callLogs) l.id]));
    }
  }

  /// Collapses consecutive calls to/from the same number on the same calendar
  /// day into one [_CallGroup] (the representative is the most recent call).
  /// Mirrors Google Phone's «(×N)» grouping.
  List<_CallGroup> _groupCallLogs(List<CallLogModel> logs) {
    final groups = <_CallGroup>[];
    var i = 0;
    while (i < logs.length) {
      final base = logs[i];
      final baseKey = _normalize(base.phoneNumber);
      final baseDay = _dayOf(base.timestamp);

      var j = i + 1;
      while (j < logs.length) {
        final next = logs[j];
        if (_normalize(next.phoneNumber) == baseKey &&
            _dayOf(next.timestamp) == baseDay) {
          j++;
        } else {
          break;
        }
      }
      groups.add(_CallGroup(logs.sublist(i, j)));
      i = j;
    }
    return groups;
  }

  /// Grouping key for consecutive calls to the same person. Must be the
  /// canonical form: a digits-only strip left `+989121234567` and `09121234567`
  /// looking like two different people, so two consecutive calls to one contact
  /// did not collapse into one «(۲)» row.
  static String _normalize(String phone) => PhoneNormalizer.toNational(phone);

  static DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}

/// Every call merged into one recents row. [logs] is ordered newest-first, so
/// the first entry is the row's representative; [ids] is what a "delete" on the
/// row must remove.
class _CallGroup {
  final List<CallLogModel> logs;
  const _CallGroup(this.logs);

  CallLogModel get representative => logs.first;
  int get count => logs.length;
  List<String> get ids => [for (final l in logs) l.id];
}

/// A row plus its position inside the day section's card run.
class _Row {
  final _CallGroup group;
  final bool isFirst;
  final bool isLast;
  const _Row({
    required this.group,
    required this.isFirst,
    required this.isLast,
  });
}
