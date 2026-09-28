import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/secure_group_store.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/secure_messages_bloc.dart';
import 'secure_conversation_screen.dart' show SecureBanner, SecureComposer;
import 'secure_group_edit_screen.dart';

/// One encrypted group (matrix row 14). SMS has no multicast: every message
/// is sealed once per member, over that member's own session — the composer
/// says what that costs. Like the one-to-one thread, nothing here can be
/// selected or copied (matrix row 22).
class SecureGroupScreen extends StatefulWidget {
  const SecureGroupScreen({super.key, required this.id, required this.name});

  final String id;
  final String name;

  @override
  State<SecureGroupScreen> createState() => _SecureGroupScreenState();
}

class _SecureGroupScreenState extends State<SecureGroupScreen> {
  final _controller = TextEditingController();
  late final SecureMessagesBloc _bloc;
  bool _deleteAfterSeen = false;

  @override
  void initState() {
    super.initState();
    _bloc = context.read<SecureMessagesBloc>();
    _bloc.add(SecureOpenGroup(widget.id));
  }

  @override
  void dispose() {
    _bloc.add(SecureCloseGroup(widget.id));
    _controller.dispose();
    super.dispose();
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _bloc.add(SecureSendGroupText(text, deleteAfterSeen: _deleteAfterSeen));
    _controller.clear();
    setState(() => _deleteAfterSeen = false);
  }

  Future<void> _confirmDelete(SecureGroup g) async {
    final scheme = Theme.of(context).colorScheme;
    final navigator = Navigator.of(context);
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف گروه؟'),
          content: Text(
            '«${g.name}» و پیام‌هایش از این گوشی پاک می‌شود. روی گوشی اعضا '
            'می‌ماند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: scheme.error),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (ok != true) return;
    _bloc.add(SecureDeleteGroup(g.id));
    navigator.pop();
  }

  void _showMembers(SecureMessagesState state, SecureGroup g) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                child: Text('اعضا', style: Theme.of(ctx).textTheme.titleMedium),
              ),
              _MemberTile(
                name: g.isMine ? 'شما' : state.nameOf(g.creator!),
                phone: g.isMine ? null : g.creator,
                badge: 'سازنده',
              ),
              if (!g.isMine) const _MemberTile(name: 'شما'),
              for (final m in g.members)
                _MemberTile(name: state.nameOf(m.phone), phone: m.phone),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
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
                message: 'این گروه داخل بخش امن است. بخش امن را باز کنید.',
              ),
            );
          }
          final g = state.groups.where((g) => g.id == widget.id).firstOrNull;
          final messages = state.openGroupId == widget.id
              ? state.openGroupMessages
              : const <SecureGroupMessage>[];
          final canSend = g != null && !g.left && !g.pendingInfo;
          final recipients = g?.recipients.length ?? 0;
          return Scaffold(
            appBar: RtlAppBar(
              titleWidget: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    (g?.name.isNotEmpty ?? false) ? g!.name : widget.name,
                    style: const TextStyle(fontSize: 18),
                  ),
                  if (g != null && !g.pendingInfo)
                    Text(
                      '${PersianUtils.toPersianNumber('${g.members.length + 1 + (g.isMine ? 0 : 1)}')} عضو · '
                      '${g.mode == SecureGroupMode.chat ? 'گفتگوی گروهی' : 'اطلاع‌رسانی'}',
                      style: TextStyle(fontSize: 12, color: scheme.primary),
                    ),
                ],
              ),
              actions: [
                if (g != null && !g.pendingInfo)
                  IconButton(
                    tooltip: 'اعضا',
                    icon: const Icon(Icons.group_outlined),
                    onPressed: () => _showMembers(state, g),
                  ),
                if (g != null && g.isMine)
                  IconButton(
                    tooltip: 'ویرایش گروه',
                    icon: const Icon(Icons.edit_outlined),
                    onPressed: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => SecureGroupEditScreen(group: g),
                      ),
                    ),
                  ),
                if (g != null)
                  IconButton(
                    tooltip: 'حذف گروه',
                    icon: const Icon(Icons.delete_outline),
                    onPressed: () => _confirmDelete(g),
                  ),
              ],
            ),
            body: Column(
              children: [
                if (g != null && g.pendingInfo)
                  const SecureBanner(
                    icon: Icons.hourglass_top,
                    text:
                        'مشخصات این گروه هنوز نرسیده است؛ تا برسد نمی‌توانید '
                        'در آن پیام بفرستید.',
                  ),
                if (g != null && g.left)
                  const SecureBanner(
                    icon: Icons.group_remove_outlined,
                    text: 'سازندهٔ گروه شما را از این گروه برداشته است.',
                  ),
                if (g != null &&
                    !g.left &&
                    !g.pendingInfo &&
                    g.mode == SecureGroupMode.announce &&
                    !g.isMine)
                  SecureBanner(
                    icon: Icons.campaign_outlined,
                    text:
                        'این گروه اطلاع‌رسانی است؛ پاسخ شما فقط به '
                        '«${state.nameOf(g.creator!)}» می‌رسد.',
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              'هر پیام این گروه جداگانه برای هر عضو رمز '
                              'می‌شود؛ فقط اعضا می‌توانند آن را بخوانند.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      : ListView.builder(
                          reverse: true,
                          padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                          itemCount: messages.length,
                          itemBuilder: (context, i) {
                            final m = messages[messages.length - 1 - i];
                            return _GroupBubble(
                              m,
                              senderName: m.sender == null
                                  ? null
                                  : state.nameOf(m.sender!),
                              names: state.names,
                            );
                          },
                        ),
                ),
                if (canSend)
                  SecureComposer(
                    controller: _controller,
                    plain: false,
                    deleteAfterSeen: _deleteAfterSeen,
                    onToggleDelete: () =>
                        setState(() => _deleteAfterSeen = !_deleteAfterSeen),
                    onSend: _send,
                    hint: 'پیام رمز گروه',
                    note: recipients <= 1
                        ? null
                        : 'به ${PersianUtils.toPersianNumber('$recipients')} '
                              'نفر · هر پیام ${PersianUtils.toPersianNumber('$recipients')} '
                              'پیامک',
                  ),
              ],
            ),
          );
        },
      ),
    );
  }
}

class _MemberTile extends StatelessWidget {
  const _MemberTile({required this.name, this.phone, this.badge});
  final String name;
  final String? phone;
  final String? badge;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 24),
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        child: Text(
          PersianUtils.getInitials(name),
          style: TextStyle(color: scheme.onPrimaryContainer),
        ),
      ),
      title: Text(name),
      subtitle: phone == null || phone == name
          ? null
          : Text(
              PersianUtils.displayPhone(phone!),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.right,
            ),
      trailing: badge == null
          ? null
          : Text(badge!, style: TextStyle(color: scheme.primary, fontSize: 12)),
    );
  }
}

class _GroupBubble extends StatelessWidget {
  const _GroupBubble(this.m, {required this.senderName, required this.names});
  final SecureGroupMessage m;
  final String? senderName;
  final Map<String, String> names;

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
          padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
          decoration: BoxDecoration(
            color: bg,
            borderRadius: BorderRadius.circular(18),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              if (senderName != null) ...[
                Text(
                  senderName!,
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    color: scheme.primary,
                  ),
                ),
                const SizedBox(height: 2),
              ],
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
                  if (mine) ...[const SizedBox(width: 6), _GroupStatus(m)],
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
    final failed = m.count(SecureMessageStatus.failed) > 0;
    final sentAny = m.deliveries.any((d) => d.counter != null);
    final action = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (m.outgoing && m.deliveries.isNotEmpty)
                ListTile(
                  leading: const Icon(Icons.checklist_rtl),
                  title: const Text('وضعیت برای هر عضو'),
                  onTap: () => Navigator.of(sheetCtx).pop('status'),
                ),
              if (m.outgoing && failed)
                ListTile(
                  leading: const Icon(Icons.refresh),
                  title: const Text('ارسال دوباره به ناموفق‌ها'),
                  onTap: () => Navigator.of(sheetCtx).pop('retry'),
                ),
              if (m.outgoing && sentAny)
                ListTile(
                  leading: const Icon(Icons.delete_sweep_outlined),
                  title: const Text('حذف برای همه'),
                  subtitle: const Text('از گوشی همهٔ اعضا هم پاک می‌شود'),
                  onTap: () => Navigator.of(sheetCtx).pop('all'),
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
    if (!context.mounted) return;
    switch (action) {
      case 'status':
        _showStatus(context);
      case 'retry':
        bloc.add(SecureRetryGroupMessage(m.id));
      case 'all':
        bloc.add(SecureGroupDeleteForAll(m.id));
      case 'local':
        bloc.add(SecureGroupDeleteLocally(m.id));
    }
  }

  void _showStatus(BuildContext context) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: ListView(
            shrinkWrap: true,
            children: [
              for (final d in m.deliveries)
                ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 24),
                  title: Text(names[d.phone] ?? d.phone),
                  trailing: Text(_statusLabel(d.status)),
                ),
              const SizedBox(height: 8),
            ],
          ),
        ),
      ),
    );
  }

  static String _statusLabel(SecureMessageStatus s) => switch (s) {
    SecureMessageStatus.queued => 'در انتظار کانال امن',
    SecureMessageStatus.sending => 'در حال ارسال',
    SecureMessageStatus.sent => 'ارسال شد',
    SecureMessageStatus.delivered => 'تحویل شد',
    SecureMessageStatus.seen => 'دیده شد',
    SecureMessageStatus.failed => 'ارسال نشد',
    SecureMessageStatus.received => '',
  };
}

/// Ours: «دیده شده ۲ از ۳», or the weakest state still pending.
class _GroupStatus extends StatelessWidget {
  const _GroupStatus(this.m);
  final SecureGroupMessage m;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final dim = scheme.onPrimaryContainer.withValues(alpha: 0.7);
    final total = m.deliveries.length;
    if (total == 0) {
      return Text(
        'گیرنده‌ای در دسترس نیست',
        style: TextStyle(fontSize: 11, color: scheme.error),
      );
    }
    final failed = m.count(SecureMessageStatus.failed);
    if (failed > 0) {
      return Text(
        '${PersianUtils.toPersianNumber('$failed')} ارسال نشد',
        style: TextStyle(fontSize: 11, color: scheme.error),
      );
    }
    final seen = m.count(SecureMessageStatus.seen);
    if (seen > 0) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.done_all, size: 14, color: scheme.primary),
          const SizedBox(width: 2),
          Text(
            'دیده شده ${PersianUtils.toPersianNumber('$seen')} از '
            '${PersianUtils.toPersianNumber('$total')}',
            style: TextStyle(fontSize: 11, color: scheme.primary),
          ),
        ],
      );
    }
    final waiting =
        m.count(SecureMessageStatus.queued) +
        m.count(SecureMessageStatus.sending);
    if (waiting > 0) return Icon(Icons.schedule, size: 14, color: dim);
    final delivered = m.count(SecureMessageStatus.delivered);
    return Icon(
      delivered == total ? Icons.done_all : Icons.done,
      size: 14,
      color: dim,
    );
  }
}
