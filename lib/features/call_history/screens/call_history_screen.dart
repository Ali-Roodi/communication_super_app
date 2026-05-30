import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/call_log_bloc.dart';
import '../bloc/call_log_event.dart';
import '../bloc/call_log_state.dart';
import '../models/call_log_model.dart';
import 'widgets/call_log_tile.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen>
    with WidgetsBindingObserver {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();

  // Memoize the grouped row list so grouping only runs when the underlying
  // data changes, not on every widget rebuild.
  List<CallLogModel>? _lastLogs;
  List<_CallGroup> _cachedGroups = [];

  List<_CallGroup> _getOrBuildGroups(List<CallLogModel> logs) {
    if (identical(_lastLogs, logs)) return _cachedGroups;
    _lastLogs = logs;
    _cachedGroups = _groupCallLogs(logs);
    return _cachedGroups;
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
    WidgetsBinding.instance.addObserver(this);
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
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh call logs when app resumes (e.g., after a phone call).
    if (state == AppLifecycleState.resumed && mounted && _hasLoadedInitially) {
      context.read<CallLogBloc>().add(const RefreshCallLogs());
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Container(
        color: theme.scaffoldBackgroundColor,
        child: BlocBuilder<CallLogBloc, CallLogState>(
          builder: (context, state) {
            if (state is CallLogLoading) {
              return const Center(child: CircularProgressIndicator());
            }

            if (state is CallLogError) {
              return Center(child: Text('خطا: ${state.message}'));
            }

            if (state is CallLogsLoaded) {
              if (state.callLogs.isEmpty) {
                return _buildEmptyState(theme);
              }

              final groups = _getOrBuildGroups(state.callLogs);

              return RefreshIndicator(
                onRefresh: () async {
                  context.read<CallLogBloc>().add(const RefreshCallLogs());
                },
                child: ListView.builder(
                  controller: _scrollController,
                  padding: const EdgeInsets.only(top: 4, bottom: 96),
                  itemCount: groups.length + (state.hasMore ? 1 : 0),
                  itemBuilder: (context, index) {
                    if (state.hasMore && index == groups.length) {
                      return const Padding(
                        padding: EdgeInsets.all(16),
                        child: Center(child: CircularProgressIndicator()),
                      );
                    }
                    final group = groups[index];
                    return CallLogTile(
                      log: group.representative,
                      count: group.count,
                    );
                  },
                ),
              );
            }

            return const SizedBox.shrink();
          },
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    final dim = theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.6);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.history, size: 96, color: dim),
          const SizedBox(height: 16),
          Text('تماس اخیری وجود ندارد', style: theme.textTheme.titleMedium),
          const SizedBox(height: 8),
          Text(
            'تماس‌های ورودی و خروجی شما اینجا نمایش داده می‌شوند',
            textAlign: TextAlign.center,
            style: theme.textTheme.bodyMedium?.copyWith(color: dim),
          ),
        ],
      ),
    );
  }

  /// Collapses consecutive calls to/from the same number on the same calendar
  /// day into one [_CallGroup] (the representative is the most recent call;
  /// [count] is how many were merged). Mirrors Google Phone's "(×N)" grouping.
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
      groups.add(_CallGroup(representative: base, count: j - i));
      i = j;
    }
    return groups;
  }

  static String _normalize(String phone) =>
      phone.replaceAll(RegExp(r'[^\d]'), '');

  static DateTime _dayOf(DateTime dt) => DateTime(dt.year, dt.month, dt.day);
}

class _CallGroup {
  final CallLogModel representative;
  final int count;
  const _CallGroup({required this.representative, required this.count});
}
