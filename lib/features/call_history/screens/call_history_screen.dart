import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import '../bloc/call_log_bloc.dart';
import '../bloc/call_log_event.dart';
import '../bloc/call_log_state.dart';
import '../models/call_log_model.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';

class CallHistoryScreen extends StatefulWidget {
  const CallHistoryScreen({super.key});

  @override
  State<CallHistoryScreen> createState() => _CallHistoryScreenState();
}

class _CallHistoryScreenState extends State<CallHistoryScreen> with WidgetsBindingObserver {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();

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
    // Refresh call logs when app resumes (e.g., after a phone call)
    // Only refresh if we've already loaded initially to avoid double-loading
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
            return Center(child: Text('Error: ${state.message}'));
          }

          if (state is CallLogsLoaded) {
            if (state.callLogs.isEmpty) {
              return const Center(
                child: Text('No call history'),
              );
            }

            final flatItems = _buildFlatCallLogList(state.callLogs);

            return RefreshIndicator(
              onRefresh: () async {
                context.read<CallLogBloc>().add(const RefreshCallLogs());
              },
              child: ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: flatItems.length + (state.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (state.hasMore && index == flatItems.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final item = flatItems[index];
                  if (item.isHeader) {
                    return _buildSectionHeader(item.title!, theme);
                  }
                  return _buildCallLogItem(context, item.log!, theme);
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

  List<_CallLogListRow> _buildFlatCallLogList(List<CallLogModel> logs) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final yesterday = today.subtract(const Duration(days: 1));

    final todayLogs = <CallLogModel>[];
    final yesterdayLogs = <CallLogModel>[];
    final olderLogs = <CallLogModel>[];

    for (var log in logs) {
      final logDate = DateTime(log.timestamp.year, log.timestamp.month, log.timestamp.day);
      if (logDate == today) {
        todayLogs.add(log);
      } else if (logDate == yesterday) {
        yesterdayLogs.add(log);
      } else {
        olderLogs.add(log);
      }
    }

    final flat = <_CallLogListRow>[];
    if (todayLogs.isNotEmpty) {
      flat.add(_CallLogListRow(title: 'امروز'));
      for (final log in todayLogs) {
        flat.add(_CallLogListRow(log: log));
      }
    }
    if (yesterdayLogs.isNotEmpty) {
      flat.add(_CallLogListRow(title: 'دیروز'));
      for (final log in yesterdayLogs) {
        flat.add(_CallLogListRow(log: log));
      }
    }
    if (olderLogs.isNotEmpty) {
      flat.add(_CallLogListRow(title: 'قدیمی‌تر'));
      for (final log in olderLogs) {
        flat.add(_CallLogListRow(log: log));
      }
    }
    return flat;
  }

  Widget _buildSectionHeader(String title, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      color: theme.brightness == Brightness.dark
          ? const Color(0xFF1A1A1A)
          : const Color(0xFFF5F5F5),
      child: Text(
        title,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: theme.textTheme.bodyMedium?.color,
        ),
        textAlign: TextAlign.right,
      ),
    );
  }

  Widget _buildCallLogItem(BuildContext context, CallLogModel log, ThemeData theme) {
    final displayName = log.contactName ?? log.phoneNumber;

    // Format time as "شبانه ۱۵:۱۷"
    final hour = log.timestamp.hour;
    final minute = log.timestamp.minute;
    final timeOfDay = hour >= 12 && hour < 18 ? 'بعدازظهر' : 'شبانه';
    final persianHour = _toPersianNumber(hour.toString().padLeft(2, '0'));
    final persianMinute = _toPersianNumber(minute.toString().padLeft(2, '0'));
    final timeString = '$timeOfDay $persianHour:$persianMinute';

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          AvatarWidget(name: displayName, size: 48),
          const SizedBox(width: 12),
          // Call details (vertical column)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  displayName,
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 4),
                Text(
                  timeString,
                  style: TextStyle(
                    fontSize: 13,
                    color: theme.textTheme.bodyMedium?.color,
                  ),
                  textAlign: TextAlign.left,
                ),
                const SizedBox(height: 4),
                Text(
                  log.simSlot != null ? 'SIM${log.simSlot}' : 'SIM1',
                  style: const TextStyle(
                    fontSize: 13,
                    color: Color(0xFF2196F3),
                    fontWeight: FontWeight.w500,
                  ),
                  textAlign: TextAlign.left,
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Avatar on the right (RTL)
          // Phone callback button on the left (RTL)
          IconButton(
            icon: const Icon(Icons.phone_outlined),
            iconSize: 24,
            color: theme.textTheme.bodyMedium?.color,
            onPressed: () async {
              await FlutterPhoneDirectCaller.callNumber(log.phoneNumber);
            },
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(
              minWidth: 40,
              minHeight: 40,
            ),
          ),
        ],
      ),
    );
  }

  String _toPersianNumber(String number) {
    const english = ['0', '1', '2', '3', '4', '5', '6', '7', '8', '9'];
    const persian = ['۰', '۱', '۲', '۳', '۴', '۵', '۶', '۷', '۸', '۹'];
    
    String result = number;
    for (int i = 0; i < english.length; i++) {
      result = result.replaceAll(english[i], persian[i]);
    }
    return result;
  }
}

class _CallLogListRow {
  final String? title;
  final CallLogModel? log;
  _CallLogListRow({this.title, this.log});
  bool get isHeader => title != null;
}

