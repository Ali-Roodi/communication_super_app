import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import '../bloc/call_log_bloc.dart';
import '../bloc/call_log_event.dart';
import '../bloc/call_log_state.dart';
import '../models/call_log_model.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/lock_button.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';

class CallHistoryScreen extends StatelessWidget {
  const CallHistoryScreen({super.key});

  @override
  Widget build(BuildContext context) {
    context.read<CallLogBloc>().add(const LoadCallLogs());

    return Scaffold(
      appBar: RtlAppBar(
        title: 'تاریخچه تماس ها',
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              // Handle search
            },
          ),
          const LockButton(),
        ],
      ),
      body: BlocBuilder<CallLogBloc, CallLogState>(
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
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 8,
                        ),
                        child: Text(
                          entry['title'] as String,
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                      ),
                      ...(entry['logs'] as List<CallLogModel>).map(
                        (log) => _buildCallLogItem(context, log),
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
      grouped.add({'title': 'قدیمی تر', 'logs': olderLogs});
    }

    return grouped;
  }

  Widget _buildCallLogItem(BuildContext context, CallLogModel log) {
    final displayName = log.contactName ?? log.phoneNumber;

    IconData icon;
    Color iconColor;
    String typeText;

    switch (log.callType) {
      case CallType.incoming:
        icon = Icons.call_received;
        iconColor = Colors.black;
        typeText = 'تماس دریافتی';
        break;
      case CallType.outgoing:
        icon = Icons.call_made;
        iconColor = Colors.black;
        typeText = 'تماس خروجی';
        break;
      case CallType.missed:
        icon = Icons.call_missed;
        iconColor = Colors.red;
        typeText = 'تماس بی پاسخ';
        break;
    }

    return ListTile(
      leading: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: iconColor, size: 20),
          const SizedBox(width: 8),
          AvatarWidget(name: displayName),
        ],
      ),
      title: Text(displayName),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 14, color: iconColor),
              const SizedBox(width: 4),
              Text(typeText),
            ],
          ),
          Text(
            DateFormatter.formatDateTime(log.timestamp),
            style: Theme.of(context).textTheme.bodySmall,
          ),
          if (log.simSlot != null)
            Text(
              'SIM${log.simSlot}',
              style: Theme.of(context).textTheme.bodySmall,
            ),
        ],
      ),
      trailing: IconButton(
        icon: const Icon(Icons.phone),
        onPressed: () async {
          await FlutterPhoneDirectCaller.callNumber(log.phoneNumber);
        },
      ),
      onTap: () async {
        await FlutterPhoneDirectCaller.callNumber(log.phoneNumber);
      },
    );
  }
}

