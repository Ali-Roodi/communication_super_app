import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_state.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/screens/widgets/call_log_tile.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';

/// Call detail bottom sheet — opened from the ⓘ icon on a recents row.
///
/// Header (avatar, name, number) + action chips, followed by the breakdown of
/// every call with this number in the currently-loaded history, then copy /
/// block actions.
Future<void> showCallDetailSheet(BuildContext context, CallLogModel log) {
  // "Calls with this contact in this session" = filter the already-loaded
  // history by normalized number (no extra DB round-trip).
  final state = context.read<CallLogBloc>().state;
  final all = state is CallLogsLoaded ? state.callLogs : const <CallLogModel>[];
  final key = _normalize(log.phoneNumber);
  final calls = all.where((l) => _normalize(l.phoneNumber) == key).toList();
  if (calls.isEmpty) calls.add(log);

  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (_) => _CallDetailSheet(log: log, calls: calls),
  );
}

class _CallDetailSheet extends StatelessWidget {
  final CallLogModel log;
  final List<CallLogModel> calls;

  const _CallDetailSheet({required this.log, required this.calls});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasName = log.contactName?.isNotEmpty == true;
    final displayName = hasName
        ? log.contactName!
        : PersianUtils.displayPhone(log.phoneNumber);
    final maxHeight = MediaQuery.of(context).size.height * 0.85;

    return Directionality(
      textDirection: TextDirection.rtl,
      child: ConstrainedBox(
        constraints: BoxConstraints(maxHeight: maxHeight),
        child: SafeArea(
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 4),
                AvatarWidget(name: displayName, size: 80),
                const SizedBox(height: 12),
                Text(
                  displayName,
                  style: theme.textTheme.titleLarge,
                  textAlign: TextAlign.center,
                ),
                if (hasName) ...[
                  const SizedBox(height: 4),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      PersianUtils.displayPhone(log.phoneNumber),
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.textTheme.bodyMedium?.color?.withValues(
                          alpha: 0.7,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 20),
                _ActionChips(log: log, hasName: hasName),
                const SizedBox(height: 12),
                const Divider(height: 1),

                // ── Activity log: calls + SMS, newest first ──────────
                _ActivityLog(calls: calls, phoneNumber: log.phoneNumber),

                const Divider(height: 1),
                FavoriteToggleTile(
                  phoneNumber: log.phoneNumber,
                  name: log.contactName,
                  contactId: log.contactId,
                  favoritesBloc: context.read<FavoritesBloc>(),
                  onDone: (added) {
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      SnackBar(
                        content: Text(
                          added
                              ? 'به موردعلاقه‌ها افزوده شد'
                              : 'از موردعلاقه‌ها حذف شد',
                        ),
                      ),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(Icons.copy_outlined),
                  title: const Text('کپی شماره'),
                  onTap: () {
                    Clipboard.setData(ClipboardData(text: log.phoneNumber));
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('شماره کپی شد')),
                    );
                  },
                ),
                ListTile(
                  leading: const Icon(
                    Icons.block,
                    color: AppColors.callRejectRed,
                  ),
                  title: const Text(
                    'مسدود کردن شماره',
                    style: TextStyle(color: AppColors.callRejectRed),
                  ),
                  onTap: () {
                    context.read<BlockedNumbersBloc>().add(
                      BlockNumber(log.phoneNumber),
                    );
                    Navigator.of(context).pop();
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(content: Text('شماره مسدود شد')),
                    );
                  },
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Action chips: Call · Message · Add/View contact ───────────────────────────

class _ActionChips extends StatelessWidget {
  final CallLogModel log;
  final bool hasName;

  const _ActionChips({required this.log, required this.hasName});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: AppDimensions.paddingMd),
      child: Row(
        children: [
          Expanded(
            child: _ActionChip(
              icon: Icons.call,
              label: 'تماس',
              onTap: () {
                Navigator.of(context).pop();
                NativeCallService.instance.makeCall(log.phoneNumber);
              },
            ),
          ),
          const SizedBox(width: AppDimensions.paddingSm),
          Expanded(
            child: _ActionChip(
              icon: Icons.message_outlined,
              label: 'پیام',
              onTap: () {
                Navigator.of(context).pop();
                Navigator.of(context).push(
                  MaterialPageRoute(
                    builder: (_) => ConversationScreen.forPhone(
                      log.phoneNumber,
                      contactName: log.contactName,
                    ),
                  ),
                );
              },
            ),
          ),
          const SizedBox(width: AppDimensions.paddingSm),
          Expanded(
            child: _ActionChip(
              icon: hasName ? Icons.person : Icons.person_add_alt,
              label: hasName ? 'مخاطب' : 'افزودن',
              onTap: () async {
                if (hasName) {
                  // Resolve the saved contact by normalized number and open its
                  // detail page.
                  final navigator = Navigator.of(context);
                  final target = PhoneNormalizer.toThreadId(log.phoneNumber);
                  ContactModel? match;
                  for (final c in await ContactRepository().getDeviceContacts()) {
                    final hit = [...c.phoneNumbers, c.phoneNumber]
                        .any((p) => PhoneNormalizer.toThreadId(p) == target);
                    if (hit) {
                      match = c;
                      break;
                    }
                  }
                  navigator.pop();
                  if (match != null) {
                    navigator.push(
                      MaterialPageRoute(
                        builder: (_) =>
                            DeviceContactDetailScreen(contact: match!),
                      ),
                    );
                  }
                } else {
                  // Capture the bloc before the sheet's context is torn down so we
                  // can refresh the recents list once the contact is saved (its
                  // name then resolves in the log).
                  final callLogBloc = context.read<CallLogBloc>();
                  final navigator = Navigator.of(context);
                  navigator.pop();
                  final saved = await navigator.push<bool>(
                    MaterialPageRoute(
                      builder: (_) =>
                          AddEditContactScreen(initialPhone: log.phoneNumber),
                    ),
                  );
                  if (saved == true) {
                    callLogBloc.add(const RefreshCallLogs());
                  }
                }
              },
            ),
          ),
        ],
      ),
    );
  }
}

class _ActionChip extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Filled light-accent rounded square (Figma 627:4073 detail actions).
    final bg = AppColors.accent.withValues(alpha: 0.12);
    return Material(
      color: bg,
      borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: theme.colorScheme.primary,
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

// ── Activity log: merged calls + SMS timeline ─────────────────────────────────

/// The per-number breakdown: every loaded call AND the recent SMS exchanged
/// with this number, merged into one newest-first timeline.
class _ActivityLog extends StatelessWidget {
  final List<CallLogModel> calls;
  final String phoneNumber;

  /// Keeps the sheet scannable — the full history lives in the conversation.
  static const int _maxSmsRows = 30;
  static const int _maxTotalRows = 50;

  const _ActivityLog({required this.calls, required this.phoneNumber});

  Future<List<MessageModel>> _loadMessages() {
    final threadId = PhoneNormalizer.toThreadId(phoneNumber);
    if (threadId.isEmpty) return Future.value(const []);
    return MessageRepository().getMessagesByThread(
      threadId,
      limit: _maxSmsRows,
      orderDesc: true,
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return FutureBuilder<List<MessageModel>>(
      future: _loadMessages(),
      builder: (context, snap) {
        final messages = snap.data ?? const <MessageModel>[];
        // Merge and sort newest-first.
        final items = <(DateTime, Widget)>[
          for (final c in calls) (c.timestamp, _CallRow(call: c, theme: theme)),
          for (final m in messages)
            (m.timestamp, _SmsRow(message: m, theme: theme)),
        ]..sort((a, b) => b.$1.compareTo(a.$1));
        return Column(
          children: [for (final it in items.take(_maxTotalRows)) it.$2],
        );
      },
    );
  }
}

/// One SMS row in the activity log (received or sent).
class _SmsRow extends StatelessWidget {
  final MessageModel message;
  final ThemeData theme;

  const _SmsRow({required this.message, required this.theme});

  @override
  Widget build(BuildContext context) {
    final received = message.type == MessageType.received;
    return ListTile(
      dense: true,
      leading: Icon(
        received ? Icons.mark_chat_unread_outlined : Icons.send_outlined,
        color: received ? AppColors.incomingCall : AppColors.outgoingCall,
        size: 20,
      ),
      title: Text(
        received ? 'پیامک دریافتی' : 'پیامک ارسالی',
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(_dateTime(message.timestamp)),
      trailing: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 120),
        child: Text(
          message.body,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
          ),
        ),
      ),
    );
  }
}

// ── Single call row in the breakdown ──────────────────────────────────────────

class _CallRow extends StatelessWidget {
  final CallLogModel call;
  final ThemeData theme;

  const _CallRow({required this.call, required this.theme});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      leading: Icon(
        _callIcon(call.callType),
        color: _callColor(call.callType),
        size: 20,
      ),
      title: Text(
        _callLabel(call.callType),
        style: const TextStyle(fontSize: 14),
      ),
      subtitle: Text(_dateTime(call.timestamp)),
      trailing: Text(
        _duration(call),
        style: TextStyle(color: theme.textTheme.bodyMedium?.color),
      ),
    );
  }
}

// ── Helpers ───────────────────────────────────────────────────────────────────

String _normalize(String phone) => phone.replaceAll(RegExp(r'[^\d]'), '');

Color _callColor(CallType type) {
  switch (type) {
    case CallType.missed:
      return AppColors.missedCallRed;
    case CallType.incoming:
      return AppColors.incomingCall;
    case CallType.outgoing:
      return AppColors.outgoingCall;
    case CallType.rejected:
      return AppColors.rejectedCall;
    case CallType.blocked:
      return AppColors.blockedCall;
  }
}

IconData _callIcon(CallType type) {
  switch (type) {
    case CallType.missed:
      return Icons.call_missed;
    case CallType.incoming:
      return Icons.call_received;
    case CallType.outgoing:
      return Icons.call_made;
    case CallType.rejected:
      return Icons.call_end;
    case CallType.blocked:
      return Icons.block;
  }
}

String _callLabel(CallType type) {
  switch (type) {
    case CallType.missed:
      return 'تماس بی‌پاسخ';
    case CallType.incoming:
      return 'تماس ورودی';
    case CallType.outgoing:
      return 'تماس خروجی';
    case CallType.rejected:
      return 'رد شده';
    case CallType.blocked:
      return 'مسدود شده';
  }
}

/// "۱۴۰۳/۰۲/۱۵ · ۱۴:۳۰" on whichever calendar Settings selected.
String _dateTime(DateTime dt) => DateFormatter.formatDateAndTime(dt);

String _duration(CallLogModel log) {
  switch (log.callType) {
    case CallType.missed:
      return 'بی‌پاسخ';
    case CallType.rejected:
      return 'رد شده';
    case CallType.blocked:
      return 'مسدود';
    case CallType.incoming:
    case CallType.outgoing:
      break;
  }
  final s = log.duration ?? 0;
  if (s == 0) return '—';
  final m = s ~/ 60;
  final sec = s % 60;
  if (m == 0) return '${PersianUtils.toPersianNumber('$sec')} ثانیه';
  final ps = PersianUtils.toPersianNumber(sec.toString().padLeft(2, '0'));
  return '${PersianUtils.toPersianNumber('$m')}:$ps';
}
