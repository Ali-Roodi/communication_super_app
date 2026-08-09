import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../bloc/scheduled_state.dart';
import '../models/scheduled_message_model.dart';
import '../models/template_wire.dart';
import 'widgets/schedule_send_sheet.dart';

/// Lists scheduled outgoing messages: upcoming (pending) first, then a history
/// section for sent / cancelled / failed ones.
class ScheduledMessagesScreen extends StatelessWidget {
  const ScheduledMessagesScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('پیام‌های زمان‌بندی‌شده')),
        body: BlocBuilder<ScheduledMessageBloc, ScheduledState>(
          builder: (context, state) {
            if (state is ScheduledLoading || state is ScheduledInitial) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is ScheduledError) {
              return Center(child: Text(state.message));
            }
            if (state is! ScheduledLoaded) return const SizedBox.shrink();

            final pending = state.pending;
            final history = state.history;
            if (pending.isEmpty && history.isEmpty) {
              return const _EmptyState();
            }
            // Virtualized: the history section grows with every delivered
            // schedule and is never trimmed.
            return CustomScrollView(
              slivers: [
                if (pending.isNotEmpty) ...[
                  const SliverToBoxAdapter(
                    child: _SectionHeader('در انتظار ارسال'),
                  ),
                  SliverList.builder(
                    itemCount: pending.length,
                    itemBuilder: (_, i) =>
                        _ScheduledTile(message: pending[i], isPending: true),
                  ),
                ],
                if (history.isNotEmpty) ...[
                  const SliverToBoxAdapter(child: _SectionHeader('تاریخچه')),
                  SliverList.builder(
                    itemCount: history.length,
                    itemBuilder: (_, i) =>
                        _ScheduledTile(message: history[i], isPending: false),
                  ),
                ],
                const SliverToBoxAdapter(child: SizedBox(height: 88)),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Re-opens the «زمان‌بندی ارسال» sheet for [message] and saves it back under
  /// the same id. Scheduling lives entirely in that sheet — there is no
  /// separate scheduling screen.
  static Future<void> reschedule(
    BuildContext context,
    ScheduledMessage message,
  ) async {
    final bloc = context.read<ScheduledMessageBloc>();
    final choice = await showScheduleSendSheet(
      context,
      initial: ScheduleChoice.fromMessage(message),
    );
    if (choice == null) return;
    bloc.add(
      SaveScheduled(
        id: message.id,
        phoneNumber: message.phoneNumber,
        contactName: message.contactName,
        body: message.body,
        scheduledAt: choice.at,
        repeat: choice.repeat,
        repeatEvery: choice.repeatEvery,
        weekdays: choice.weekdays,
        jitter: choice.jitter,
        endType: choice.endType,
        endDate: choice.endDate,
        maxOccurrences: choice.maxOccurrences,
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  final String title;
  const _SectionHeader(this.title);

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Text(
        title,
        style: Theme.of(context).textTheme.titleSmall?.copyWith(
          color: Theme.of(context).colorScheme.primary,
        ),
      ),
    );
  }
}

class _ScheduledTile extends StatelessWidget {
  final ScheduledMessage message;
  final bool isPending;

  const _ScheduledTile({required this.message, required this.isPending});

  String _fa(String s) => PersianUtils.toPersianNumber(s);

  String get _recipient => (message.contactName?.isNotEmpty ?? false)
      ? message.contactName!
      : PersianUtils.displayPhone(message.phoneNumber);

  String _repeatSummary() {
    final unit = switch (message.repeat) {
      ScheduleRepeat.none => null,
      ScheduleRepeat.daily => 'روز',
      ScheduleRepeat.weekly => 'هفته',
      ScheduleRepeat.monthly => 'ماه',
    };
    if (unit == null) return 'یک‌بار';
    final n = message.repeatEvery > 1
        ? '${_fa('${message.repeatEvery}')} '
        : '';
    return 'هر $n$unit';
  }

  String _statusLabel() => switch (message.status) {
    ScheduleStatus.pending => message.attemptCount > 0 ? 'تلاش مجدد' : '',
    ScheduleStatus.sending => 'در حال ارسال',
    ScheduleStatus.completed => 'انجام شد',
    ScheduleStatus.cancelled => 'لغو شد',
    ScheduleStatus.failed => 'ناموفق',
  };

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: isPending
            ? theme.colorScheme.primaryContainer
            : theme.colorScheme.surfaceContainerHighest,
        child: Icon(
          isPending ? Icons.schedule : Icons.history,
          size: 20,
          color: isPending ? theme.colorScheme.onPrimaryContainer : null,
        ),
      ),
      title: Text(_recipient, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            // A scheduled template holds its compact payload — show the message.
            TemplateWire.displayText(message.body),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 2),
          Text(
            '${_fa(DateFormatter.formatDateTime(message.scheduledAt))} · ${_repeatSummary()}'
            // The window matters as much as the time — without it the row
            // claims a precision the send does not have.
            '${message.jitter == JitterWindow.none ? '' : ' · ${jitterLabel(message.jitter)} پراکندگی'}'
            '${isPending ? '' : ' · ${_statusLabel()}'}',
            style: theme.textTheme.bodySmall,
          ),
        ],
      ),
      isThreeLine: true,
      trailing: isPending
          ? PopupMenuButton<String>(
              onSelected: (v) {
                final bloc = context.read<ScheduledMessageBloc>();
                switch (v) {
                  case 'now':
                    bloc.add(SendScheduledNow(message.id));
                  case 'reschedule':
                    ScheduledMessagesScreen.reschedule(context, message);
                  case 'cancel':
                    bloc.add(CancelScheduled(message.id));
                  case 'delete':
                    bloc.add(DeleteScheduled(message.id));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'now', child: Text('ارسال فوری')),
                PopupMenuItem(value: 'reschedule', child: Text('تغییر زمان')),
                PopupMenuItem(value: 'cancel', child: Text('لغو')),
                PopupMenuItem(value: 'delete', child: Text('حذف')),
              ],
            )
          : IconButton(
              icon: const Icon(Icons.delete_outline, color: AppColors.danger),
              tooltip: 'حذف',
              onPressed: () => context.read<ScheduledMessageBloc>().add(
                DeleteScheduled(message.id),
              ),
            ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.schedule_send_outlined,
            size: 64,
            color: theme.colorScheme.outline,
          ),
          const SizedBox(height: 16),
          const Text('پیام زمان‌بندی‌شده‌ای نیست'),
          const SizedBox(height: 4),
          Text(
            'در گفتگو، دکمهٔ ارسال را نگه دارید تا پیام زمان‌بندی شود',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
