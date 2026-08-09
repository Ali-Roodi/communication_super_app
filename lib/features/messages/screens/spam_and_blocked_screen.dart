import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import '../models/template_wire.dart';
import '../repositories/message_repository.dart';
import 'conversation_screen.dart';

/// «هرزنامه و مسدودشده» — where a blocked conversation goes.
///
/// This replaced the old settings-only «شماره‌های مسدود» list, which was the
/// whole reason blocking felt broken: the number went into a table nothing
/// visible reflected, the conversation stayed sitting in the inbox, and the
/// user had no way to tell a block had happened at all. Google Messages moves
/// the conversation *out* of the inbox and into this page, keeps its contents
/// readable, and offers the one action that matters on each row — رفع مسدودی.
///
/// Reported entries lead: «هرزنامه» is what brings anyone here.
class SpamAndBlockedScreen extends StatefulWidget {
  const SpamAndBlockedScreen({super.key});

  @override
  State<SpamAndBlockedScreen> createState() => _SpamAndBlockedScreenState();
}

class _SpamAndBlockedScreenState extends State<SpamAndBlockedScreen> {
  final MessageRepository _messages = MessageRepository();

  /// Per blocked key: the contact name (or null) and the newest message body,
  /// resolved once. The list is small — tens of rows at most — but it is still
  /// one query per row, so the answers are cached rather than re-read on every
  /// rebuild of the bloc's state.
  final Map<String, _BlockedRowDetail> _details = {};
  final Set<String> _resolving = {};

  @override
  void initState() {
    super.initState();
    context.read<BlockedNumbersBloc>().add(const LoadBlocked());
  }

  Future<void> _resolve(BlockedNumberModel number) async {
    if (!_resolving.add(number.normalized)) return;
    String? name;
    try {
      name = (await ContactRepository().getContactByPhoneNumber(
        number.phoneNumber,
      ))?.name;
    } catch (_) {
      // No contacts permission — the row still reads fine as a number.
    }
    final last = await _messages.getMessagesByThread(
      number.normalized,
      limit: 1,
      orderDesc: true,
    );
    if (!mounted) return;
    setState(() {
      _details[number.normalized] = _BlockedRowDetail(
        contactName: name,
        lastMessage: last.isEmpty
            ? null
            : TemplateWire.displayText(last.first.body),
        lastMessageTime: last.isEmpty ? null : last.first.timestamp,
      );
    });
  }

  void _unblock(BlockedNumberModel number, {required String label}) {
    final bloc = context.read<BlockedNumbersBloc>();
    bloc.add(UnblockNumber(number.normalized));
    // Bringing the conversation back into the inbox is the inbox's own job: it
    // listens for the blocked set changing, so it reloads *after* the row is
    // gone rather than racing the delete.
    showUndoSnack(
      context,
      message: '«$label» از مسدودی خارج شد',
      onUndo: () =>
          bloc.add(BlockNumber(number.phoneNumber, report: number.isSpam)),
    );
  }

  Future<void> _addNumber() async {
    final controller = TextEditingController();
    final raw = await showDialog<String>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('افزودن شماره'),
          content: Directionality(
            textDirection: TextDirection.ltr,
            child: TextField(
              controller: controller,
              autofocus: true,
              keyboardType: TextInputType.phone,
              textAlign: TextAlign.right,
              inputFormatters: [
                FilteringTextInputFormatter.allow(RegExp(r'[\d+\-\s()]')),
              ],
              onSubmitted: (v) => Navigator.pop(dialogContext, v),
              decoration: const InputDecoration(hintText: '09xxxxxxxxx'),
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, controller.text),
              child: const Text('مسدود کردن'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (!mounted || raw == null) return;
    if (BlockedNumberModel.normalize(raw).isEmpty) return;
    context.read<BlockedNumbersBloc>().add(BlockNumber(raw));
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(
          title: 'هرزنامه و مسدودشده',
          actions: [
            IconButton(
              icon: const Icon(Icons.add),
              tooltip: 'افزودن شماره',
              onPressed: _addNumber,
            ),
          ],
        ),
        body: BlocBuilder<BlockedNumbersBloc, BlockedNumbersState>(
          builder: (context, state) {
            if (state is BlockedNumbersError) {
              return Center(child: Text(state.message));
            }
            if (state is! BlockedNumbersLoaded) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state.numbers.isEmpty) {
              return const EmptyState(
                icon: Icons.block,
                title: 'چیزی مسدود نشده است',
                subtitle:
                    'شماره‌هایی که مسدود یا به‌عنوان هرزنامه گزارش کنید، '
                    'همراه گفتگویشان اینجا نگه داشته می‌شوند',
              );
            }

            final spam = state.spam;
            final blocked = state.blockedOnly;
            return ListView(
              padding: const EdgeInsets.only(top: 4, bottom: 32),
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 4),
                  child: Text(
                    'تماس‌ها و پیامک‌های این شماره‌ها رد می‌شوند و گفتگویشان از '
                    'صندوق پیام‌ها بیرون است.',
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                if (spam.isNotEmpty) ...[
                  const SectionLabel('هرزنامه'),
                  GroupedList(
                    children: [for (final n in spam) _row(n)],
                  ),
                ],
                if (blocked.isNotEmpty) ...[
                  const SectionLabel('مسدودشده'),
                  GroupedList(
                    children: [for (final n in blocked) _row(n)],
                  ),
                ],
              ],
            );
          },
        ),
      ),
    );
  }

  Widget _row(BlockedNumberModel number) {
    final detail = _details[number.normalized];
    if (detail == null) _resolve(number);
    return _BlockedRow(
      key: ValueKey(number.normalized),
      number: number,
      detail: detail,
      onUnblock: (label) => _unblock(number, label: label),
      onToggleReport: (label) {
        final bloc = context.read<BlockedNumbersBloc>();
        if (number.isSpam) {
          bloc.add(ClearSpamReport(number.normalized));
          showUndoSnack(context, message: 'گزارش هرزنامه «$label» برداشته شد');
        } else {
          bloc.add(BlockNumber(number.phoneNumber, report: true));
          showUndoSnack(context, message: '«$label» به‌عنوان هرزنامه گزارش شد');
        }
      },
    );
  }
}

class _BlockedRowDetail {
  final String? contactName;
  final String? lastMessage;
  final DateTime? lastMessageTime;
  const _BlockedRowDetail({
    this.contactName,
    this.lastMessage,
    this.lastMessageTime,
  });
}

class _BlockedRow extends StatelessWidget {
  const _BlockedRow({
    super.key,
    required this.number,
    required this.detail,
    required this.onUnblock,
    required this.onToggleReport,
  });

  final BlockedNumberModel number;
  final _BlockedRowDetail? detail;

  /// Both callbacks receive the label to name in the confirmation, so the
  /// snack bar says «علی» rather than the raw digits when a contact is known.
  final ValueChanged<String> onUnblock;
  final ValueChanged<String> onToggleReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = PersianUtils.displayPhone(
      PhoneNormalizer.toNational(number.phoneNumber),
    );
    final name = detail?.contactName;
    final label = (name == null || name.isEmpty) ? display : name;
    final preview = detail?.lastMessage;

    return ListTile(
      leading: PhoneContactAvatar(
        phoneNumber: number.phoneNumber,
        name: label,
        size: 44,
      ),
      title: Row(
        children: [
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
          if (number.isSpam) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
              decoration: BoxDecoration(
                color: theme.colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                'هرزنامه',
                style: theme.textTheme.labelSmall?.copyWith(
                  color: theme.colorScheme.onErrorContainer,
                ),
              ),
            ),
          ],
        ],
      ),
      subtitle: Text(
        preview == null || preview.isEmpty
            ? (name == null || name.isEmpty ? 'بدون گفتگو' : display)
            : preview.replaceAll('\n', ' '),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: PopupMenuButton<String>(
        onSelected: (value) => switch (value) {
          'unblock' => onUnblock(label),
          'report' => onToggleReport(label),
          _ => null,
        },
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'unblock', child: Text('رفع مسدودی')),
          PopupMenuItem(
            value: 'report',
            child: Text(
              number.isSpam ? 'این هرزنامه نیست' : 'گزارش هرزنامه',
            ),
          ),
        ],
      ),
      // The conversation stays readable — Google keeps blocked messages, it
      // just stops surfacing them. Opening it does not unblock anything.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ConversationScreen.forPhone(
            number.phoneNumber,
            contactName: name,
          ),
        ),
      ),
    );
  }
}
