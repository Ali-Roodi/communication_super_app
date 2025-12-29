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
  @override
  void initState() {
    super.initState();
    // Load call logs once when screen initializes
    context.read<CallLogBloc>().add(const LoadCallLogs());
    // Add lifecycle observer to detect when app resumes from background
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // Refresh call logs when app resumes (e.g., after a phone call)
    if (state == AppLifecycleState.resumed) {
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

            final grouped = _groupCallLogsByDate(state.callLogs);

            return RefreshIndicator(
              onRefresh: () async {
                context.read<CallLogBloc>().add(const RefreshCallLogs());
              },
              child: ListView.builder(
                itemCount: grouped.length,
                itemBuilder: (context, index) {
                  final entry = grouped[index];
                  return Column(
                      crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                        // Section header
                        Container(
                          width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                            horizontal: 20,
                          vertical: 8,
                        ),
                          color: theme.brightness == Brightness.dark
                              ? const Color(0xFF1A1A1A)
                              : const Color(0xFFF5F5F5),
                        child: Text(
                          entry['title'] as String,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                              color: theme.textTheme.bodyMedium?.color,
                            ),
                            textAlign: TextAlign.right,
                        ),
                      ),
                        // Call logs in this section
                      ...(entry['logs'] as List<CallLogModel>).map(
                          (log) => _buildCallLogItem(context, log, theme),
                      ),
                    ],
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

  List<Map<String, dynamic>> _groupCallLogsByDate(
    List<CallLogModel> logs,
  ) {
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

    final grouped = <Map<String, dynamic>>[];
    if (todayLogs.isNotEmpty) {
      grouped.add({'title': 'امروز', 'logs': todayLogs});
    }
    if (yesterdayLogs.isNotEmpty) {
      grouped.add({'title': 'دیروز', 'logs': yesterdayLogs});
    }
    if (olderLogs.isNotEmpty) {
      grouped.add({'title': 'قدیمی‌تر', 'logs': olderLogs});
    }

    return grouped;
  }

  Widget _buildCallLogItem(BuildContext context, CallLogModel log, ThemeData theme) {
    final displayName = log.contactName ?? log.phoneNumber;

    IconData callIcon;
    Color iconColor;

    switch (log.callType) {
      case CallType.incoming:
        callIcon = Icons.call_received;
        iconColor = theme.brightness == Brightness.dark 
            ? Colors.white70 
            : Colors.black87;
        break;
      case CallType.outgoing:
        callIcon = Icons.call_made;
        iconColor = theme.brightness == Brightness.dark 
            ? Colors.white70 
            : Colors.black87;
        break;
      case CallType.missed:
        callIcon = Icons.call_missed;
        iconColor = const Color(0xFFE53935);
        break;
    }

    // Format time as "شبانه ۱۵:۱۷"
    final hour = log.timestamp.hour;
    final minute = log.timestamp.minute;
    final timeOfDay = hour >= 12 && hour < 18 ? 'بعدازظهر' : 'شبانه';
    final persianHour = _toPersianNumber(hour.toString().padLeft(2, '0'));
    final persianMinute = _toPersianNumber(minute.toString().padLeft(2, '0'));
    final timeString = '$timeOfDay $persianHour:$persianMinute';

    return InkWell(
      onTap: () async {
        await FlutterPhoneDirectCaller.callNumber(log.phoneNumber);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
        children: [
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
            const SizedBox(width: 12),
            // Call details
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
        children: [
                  Text(
                    displayName,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  const SizedBox(height: 4),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.end,
            children: [
                      Text(
                        timeString,
                        style: TextStyle(
                          fontSize: 13,
                          color: iconColor,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Icon(
                        callIcon,
                        size: 16,
                        color: iconColor,
                      ),
            ],
          ),
                  const SizedBox(height: 4),
          Text(
                    log.simSlot != null ? 'SIM${log.simSlot}' : 'SIM1',
                    style: const TextStyle(
                      fontSize: 13,
                      color: Color(0xFF2196F3),
                      fontWeight: FontWeight.w500,
                    ),
                    textAlign: TextAlign.right,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Avatar on the right (RTL)
            AvatarWidget(name: displayName, size: 48),
          ],
        ),
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

