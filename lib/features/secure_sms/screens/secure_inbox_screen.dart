import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/secure_messages_bloc.dart';
import 'secure_conversation_screen.dart';
import 'secure_new_conversation_screen.dart';

/// «پیام‌های رمز» — the encrypted conversations. Reached from the row at the
/// top of the inbox (only while the secure section is open) and from the
/// «پیام رمز جدید» notification.
class SecureInboxScreen extends StatelessWidget {
  const SecureInboxScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<SecureMessagesBloc, SecureMessagesState>(
        builder: (context, state) {
          final ready = state.status == SecureMessagesStatus.ready;
          return Scaffold(
            appBar: RtlAppBar(
              title: 'پیام‌های رمز',
              actions: [
                if (ready)
                  PopupMenuButton<bool>(
                    tooltip: 'گزینه‌های بیشتر',
                    onSelected: (on) => context.read<SecureMessagesBloc>().add(
                      SecureSetReceipts(on),
                    ),
                    itemBuilder: (_) => [
                      CheckedPopupMenuItem<bool>(
                        value: !state.sendsReceipts,
                        checked: state.sendsReceipts,
                        child: const Text('ارسال «دیده شد»'),
                      ),
                    ],
                  ),
              ],
            ),
            body: switch (state.status) {
              SecureMessagesStatus.locked => const SecureLockedView(
                message:
                    'پیام‌های رمز داخل بخش امن نگهداری می‌شوند. برای دیدن آن‌ها، '
                    'بخش امن را باز کنید.',
              ),
              SecureMessagesStatus.loading => const SizedBox.shrink(),
              SecureMessagesStatus.ready =>
                state.conversations.isEmpty
                    ? const _Empty()
                    : ListView.separated(
                        padding: const EdgeInsets.only(top: 8, bottom: 96),
                        itemCount: state.conversations.length,
                        separatorBuilder: (_, _) =>
                            const Divider(height: 1, indent: 84),
                        itemBuilder: (context, i) =>
                            _ConversationRow(state.conversations[i]),
                      ),
            },
            floatingActionButton: ready
                ? FloatingActionButton.extended(
                    heroTag: 'secure_fab',
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => const SecureNewConversationScreen(),
                      ),
                    ),
                    icon: const Icon(Icons.enhanced_encryption_outlined),
                    label: const Text('گفتگوی رمز'),
                  )
                : null,
          );
        },
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty();

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.enhanced_encryption_outlined,
              size: 48,
              color: scheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text('هنوز گفتگوی رمزی ندارید', textAlign: TextAlign.center),
            const SizedBox(height: 8),
            Text(
              'برای شروع، «گفتگوی رمز» را بزنید. کسانی که کلیدشان در بانک کلید '
              'است، در فهرست دیده می‌شوند.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
            ),
          ],
        ),
      ),
    );
  }
}

class _ConversationRow extends StatelessWidget {
  const _ConversationRow(this.c);
  final SecureConversation c;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final unread = c.unread > 0;
    final preview = c.lastBody == null
        ? (c.encrypted ? 'در انتظار برقراری کانال امن' : 'بدون پیام')
        : (c.lastOutgoing ? 'شما: ${c.lastBody}' : c.lastBody!);
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              SecureConversationScreen(phone: c.phone, name: c.name),
        ),
      ),
      onLongPress: () => _confirmDelete(context),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            CircleAvatar(
              radius: 26,
              backgroundColor: scheme.primaryContainer,
              child: Icon(Icons.lock, color: scheme.onPrimaryContainer),
            ),
            const SizedBox(width: 16),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    c.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: unread ? FontWeight.w700 : FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    preview,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      color: unread
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                      fontWeight: unread ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  DateFormatter.formatRelative(
                    DateTime.fromMillisecondsSinceEpoch(c.lastAt),
                  ),
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(height: 6),
                if (unread)
                  Container(
                    constraints: const BoxConstraints(minWidth: 22),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: scheme.primary,
                      borderRadius: BorderRadius.circular(11),
                    ),
                    child: Text(
                      PersianUtils.toPersianNumber('${c.unread}'),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: scheme.onPrimary, fontSize: 12),
                    ),
                  )
                else
                  const SizedBox(height: 18),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _confirmDelete(BuildContext context) async {
    final bloc = context.read<SecureMessagesBloc>();
    final scheme = Theme.of(context).colorScheme;
    final ok = await showDialog<bool>(
      context: context,
      builder: (dialogCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف گفتگو؟'),
          content: Text(
            'گفتگوی رمز با «${c.name}» از این گوشی پاک می‌شود. پیام‌ها روی گوشی '
            'طرف مقابل می‌مانند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogCtx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => Navigator.of(dialogCtx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok == true) bloc.add(SecureDeleteConversation(c.phone));
  }
}
