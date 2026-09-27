import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/secure_messages_bloc.dart';

/// One encrypted conversation.
///
/// Deliberately plainer than the normal chat: the text cannot be selected or
/// copied (matrix row 22 — the screen is also FLAG_SECURE while the section is
/// open), and there is no forwarding. Long-press offers only what applies to
/// an encrypted message: «حذف برای هر دو», «حذف», «ارسال دوباره».
class SecureConversationScreen extends StatefulWidget {
  const SecureConversationScreen({
    super.key,
    required this.phone,
    required this.name,
  });

  final String phone;
  final String name;

  @override
  State<SecureConversationScreen> createState() =>
      _SecureConversationScreenState();
}

class _SecureConversationScreenState extends State<SecureConversationScreen> {
  final _controller = TextEditingController();
  late final SecureMessagesBloc _bloc;
  bool _deleteAfterSeen = false;

  @override
  void initState() {
    super.initState();
    _bloc = context.read<SecureMessagesBloc>();
    _bloc.add(SecureOpenThread(widget.phone));
  }

  @override
  void dispose() {
    _bloc.add(SecureCloseThread(widget.phone));
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _bloc.add(SecureSendText(text, deleteAfterSeen: _deleteAfterSeen));
    _controller.clear();
    setState(() => _deleteAfterSeen = false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<SecureMessagesBloc, SecureMessagesState>(
        builder: (context, state) {
          if (state.status == SecureMessagesStatus.locked) {
            return Scaffold(
              appBar: RtlAppBar(title: widget.name),
              body: const SecureLockedView(
                message: 'این گفتگو داخل بخش امن است. بخش امن را باز کنید.',
              ),
            );
          }
          final messages = state.openPhone == widget.phone
              ? state.openMessages
              : const <SecureMessage>[];
          return Scaffold(
            appBar: RtlAppBar(
              titleWidget: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(widget.name, style: const TextStyle(fontSize: 18)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.lock, size: 12, color: scheme.primary),
                      const SizedBox(width: 4),
                      Text(
                        'رمزشده پساکوانتومی',
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            body: Column(
              children: [
                if (state.openPhone == widget.phone && state.handshakePending)
                  _Banner(
                    icon: Icons.sync_lock,
                    text:
                        'در حال برقراری کانال امن. پیام‌ها پس از پاسخ گوشی مقابل '
                        'ارسال می‌شوند.',
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'پیام‌های این گفتگو با کلیدی که فقط شما دو نفر '
                              'دارید رمز می‌شوند.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: messages.length,
                          itemBuilder: (context, i) =>
                              _Bubble(messages[messages.length - 1 - i]),
                        ),
                ),
                _Composer(
                  controller: _controller,
                  deleteAfterSeen: _deleteAfterSeen,
                  onToggleDelete: () =>
                      setState(() => _deleteAfterSeen = !_deleteAfterSeen),
                  onSend: _send,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.icon, required this.text});
  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.secondaryContainer,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 20, color: scheme.onSecondaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 13,
                color: scheme.onSecondaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m);
  final SecureMessage m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final mine = m.outgoing;
    final bg = mine ? scheme.primaryContainer : scheme.surfaceContainerHighest;
    final fg = mine ? scheme.onPrimaryContainer : scheme.onSurface;
    final time = DateFormatter.formatTime(
      DateTime.fromMillisecondsSinceEpoch(m.timestamp),
    );
    return Align(
      // RTL: the start is the right edge — ours sit there, as in the inbox.
      alignment: mine
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      child: GestureDetector(
        onLongPress: () => _actions(context),
        child: Container(
          constraints: BoxConstraints(
            maxWidth: MediaQuery.sizeOf(context).width * 0.78,
          ),
          margin: const EdgeInsets.symmetric(vertical: 3),
          padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                m.body,
                style: TextStyle(fontSize: 16, color: fg, height: 1.4),
              ),
              const SizedBox(height: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (m.deleteAfterSeen) ...[
                    Icon(
                      Icons.timer_outlined,
                      size: 13,
                      color: fg.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 4),
                  ],
                  Text(
                    time,
                    style: TextStyle(
                      fontSize: 11,
                      color: fg.withValues(alpha: 0.7),
                    ),
                  ),
                  if (mine) ...[const SizedBox(width: 6), _StatusMark(m)],
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _actions(BuildContext context) async {
    HapticFeedback.mediumImpact();
    final bloc = context.read<SecureMessagesBloc>();
    final canDeleteForBoth = m.outgoing && m.counter != null;
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.status == SecureMessageStatus.failed)
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('ارسال دوباره'),
                  onTap: () => Navigator.of(sheetCtx).pop('retry'),
                ),
              if (canDeleteForBoth)
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('حذف برای هر دو'),
                  subtitle: const Text('از گوشی طرف مقابل هم پاک می‌شود'),
                  onTap: () => Navigator.of(sheetCtx).pop('both'),
                ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('حذف از این گوشی'),
                onTap: () => Navigator.of(sheetCtx).pop('local'),
              ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
    switch (action) {
      case 'retry':
        bloc.add(SecureRetry(m.id));
      case 'both':
        bloc.add(SecureDeleteForBoth(m.id));
      case 'local':
        bloc.add(SecureDeleteLocally(m.id));
    }
  }
}

class _StatusMark extends StatelessWidget {
  const _StatusMark(this.m);
  final SecureMessage m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = scheme.onPrimaryContainer.withValues(alpha: 0.7);
    return switch (m.status) {
      SecureMessageStatus.queued => Icon(Icons.schedule, size: 14, color: dim),
      SecureMessageStatus.sending => Icon(Icons.schedule, size: 14, color: dim),
      SecureMessageStatus.sent => Icon(Icons.done, size: 14, color: dim),
      SecureMessageStatus.delivered => Icon(
        Icons.done_all,
        size: 14,
        color: dim,
      ),
      SecureMessageStatus.seen => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all, size: 14, color: scheme.primary),
          const SizedBox(width: 2),
          Text(
            'دیده شد',
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
        ],
      ),
      SecureMessageStatus.failed => Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 14, color: scheme.error),
          const SizedBox(width: 2),
          Text(
            'ارسال نشد',
            style: TextStyle(fontSize: 11, color: scheme.error),
          ),
        ],
      ),
      SecureMessageStatus.received => const SizedBox.shrink(),
    };
  }
}

class _Composer extends StatelessWidget {
  const _Composer({
    required this.controller,
    required this.deleteAfterSeen,
    required this.onToggleDelete,
    required this.onSend,
  });

  final TextEditingController controller;
  final bool deleteAfterSeen;
  final VoidCallback onToggleDelete;
  final VoidCallback onSend;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (deleteAfterSeen)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  children: [
                    Icon(Icons.timer_outlined, size: 16, color: scheme.primary),
                    const SizedBox(width: 6),
                    Text(
                      'این پیام پس از دیده شدن از گوشی گیرنده پاک می‌شود',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  tooltip: 'حذف پس از دیدن',
                  isSelected: deleteAfterSeen,
                  icon: const Icon(Icons.timer_outlined),
                  selectedIcon: const Icon(Icons.timer),
                  color: deleteAfterSeen ? scheme.primary : null,
                  onPressed: onToggleDelete,
                ),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    // The encrypted text must not end up in a keyboard's
                    // learned words or clipboard suggestions.
                    enableSuggestions: false,
                    autocorrect: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: const InputDecoration(hintText: 'پیام رمز'),
                  ),
                ),
                const SizedBox(width: 6),
                ValueListenableBuilder<TextEditingValue>(
                  valueListenable: controller,
                  builder: (context, value, _) => IconButton.filled(
                    tooltip: 'ارسال',
                    onPressed: value.text.trim().isEmpty ? null : onSend,
                    icon: const Icon(Icons.send),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
