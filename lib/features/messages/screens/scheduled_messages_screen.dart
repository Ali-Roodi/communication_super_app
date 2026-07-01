import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../bloc/scheduled_state.dart';
import '../models/scheduled_message_model.dart';
import 'schedule_message_screen.dart';

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
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'scheduled_fab',
          onPressed: () => _openEditor(context),
          icon: const Icon(Icons.add),
          label: const Text('زمان‌بندی جدید'),
        ),
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
            return ListView(
              padding: const EdgeInsets.only(bottom: 88),
              children: [
                if (pending.isNotEmpty) ...[
                  const _SectionHeader('در انتظار ارسال'),
                  for (final m in pending)
                    _ScheduledTile(message: m, isPending: true),
                ],
                if (history.isNotEmpty) ...[
                  const _SectionHeader('تاریخچه'),
                  for (final m in history)
                    _ScheduledTile(message: m, isPending: false),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  static Future<void> _openEditor(
    BuildContext context, {
    ScheduledMessage? existing,
  }) {
    final bloc = context.read<ScheduledMessageBloc>();
    return Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: bloc,
          child: ScheduleMessageScreen(existing: existing),
        ),
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
      : _fa(message.phoneNumber);

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
    ScheduleStatus.pending => '',
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
          Text(message.body, maxLines: 1, overflow: TextOverflow.ellipsis),
          const SizedBox(height: 2),
          Text(
            '${_fa(DateFormatter.formatDateTime(message.scheduledAt))} · ${_repeatSummary()}'
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
                  case 'edit':
                    ScheduledMessagesScreen._openEditor(
                      context,
                      existing: message,
                    );
                  case 'cancel':
                    bloc.add(CancelScheduled(message.id));
                  case 'delete':
                    bloc.add(DeleteScheduled(message.id));
                }
              },
              itemBuilder: (_) => const [
                PopupMenuItem(value: 'edit', child: Text('ویرایش')),
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
            'با دکمهٔ + یک پیام را برای ارسال خودکار زمان‌بندی کنید',
            style: theme.textTheme.bodySmall,
            textAlign: TextAlign.center,
          ),
        ],
      ),
    );
  }
}
