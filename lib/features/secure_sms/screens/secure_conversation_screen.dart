import 'dart:async';
import 'package:communication_super_app/core/widgets/infinite_scroll.dart';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/secure_message_store.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/secure_messages_bloc.dart';
import '../services/secure_messenger.dart';

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

/// How long a session request may go unanswered before the screen says so.
/// The answer is two SMS parts; between two phones that are on it takes
/// seconds.
const _noAnswerAfter = Duration(minutes: 2);

/// What the conversation screen says about its secure channel.
enum _Channel { none, connecting, requestFailed, noAnswer }

class _SecureConversationScreenState extends State<SecureConversationScreen> {
  final _controller = TextEditingController();
  late final SecureMessagesBloc _bloc;
  SecureExpiry _expiry = SecureExpiry.none;

  /// Re-reads the clock while the screen is up: «پاسخی نرسید» is about time
  /// passing, not about a new state.
  Timer? _tick;

  @override
  void initState() {
    super.initState();
    _bloc = context.read<SecureMessagesBloc>();
    _bloc.add(SecureOpenThread(widget.phone));
    _tick = Timer.periodic(const Duration(seconds: 15), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _tick?.cancel();
    _bloc.add(SecureCloseThread(widget.phone));
    _controller.dispose();
    super.dispose();
  }

  static int _now() => DateTime.now().millisecondsSinceEpoch;

  _Channel _channel(SecureMessagesState state) {
    if (state.openPhone != widget.phone || !state.handshakePending) {
      return _Channel.none;
    }
    final c = state.channel;
    if (c.requestFailed) return _Channel.requestFailed;
    final since = c.pendingSince;
    if (since != null && _now() - since > _noAnswerAfter.inMilliseconds) {
      return _Channel.noAnswer;
    }
    return _Channel.connecting;
  }

  void _send() {
    final text = _controller.text.trim();
    if (text.isEmpty) return;
    HapticFeedback.selectionClick();
    _bloc.add(
      SecureSendText(
        text,
        deleteAfterSeen: _expiry.deleteAfterSeen,
        ttl: _expiry.ttl,
      ),
    );
    _controller.clear();
    setState(() => _expiry = SecureExpiry.none);
  }

  /// The «پیام‌های رمز» menu's card, else the phone's default for SMS.
  static SimCard? _generalSim(SecureMessagesState state) =>
      SimService.byId(state.smsSim) ?? SimService.defaultFor(SimUse.sms);

  /// The card this conversation's next SMS leaves on — the same choice
  /// `SecureMessenger` makes: its own, else the menu's, else the default;
  /// a card no longer in the phone is passed over.
  SimCard? _sim() {
    final state = _bloc.state;
    return SimService.byId(state.threadSims[widget.phone]) ??
        _generalSim(state);
  }

  /// «سیم‌کارت ارسال»: this conversation's own card (row 5 of the mentor's
  /// list: as Telegram's secret chats, one setting per chat over the menu's).
  Future<void> _pickSim() async {
    final state = _bloc.state;
    final own = SimService.byId(state.threadSims[widget.phone]);
    final general = _generalSim(state);
    final chosen = await showSimChoice(
      context,
      title: 'ارسال با کدام سیم‌کارت؟',
      subtitle: 'فقط برای این گفتگو',
      defaultLabel: 'طبق تنظیم «پیام‌های رمز»',
      defaultSubtitle: general == null
          ? null
          : '${general.slotLabel} · ${general.name}',
      selected: own,
      defaultSelected: own == null,
    );
    if (chosen == null || !mounted) return;
    _bloc.add(SecureSetThreadSim(widget.phone, chosen.sim?.subscriptionId));
  }

  static String _coverLabel(String? mode) => switch (mode) {
    'fa' => 'فارسی',
    'en' => 'انگلیسی',
    _ => 'خاموش',
  };

  /// «متن پوششی» for this conversation only (organization edition).
  Future<void> _pickCover() async {
    final state = _bloc.state;
    final own = state.threadCovers[widget.phone];
    final scheme = Theme.of(context).colorScheme;
    // '' = follow the menu; otherwise `off`, `fa` or `en`.
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) {
        Widget row(String value, String title, {String? subtitle}) => ListTile(
          title: Text(title),
          subtitle: subtitle == null ? null : Text(subtitle),
          trailing: (own ?? '') == value
              ? Icon(Icons.check, color: scheme.primary)
              : null,
          onTap: () => Navigator.of(sheetCtx).pop(value),
        );
        return Directionality(
          textDirection: TextDirection.rtl,
          child: SafeArea(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 4),
                  child: Text(
                    'متن پوششی این گفتگو',
                    style: Theme.of(sheetCtx).textTheme.titleMedium,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
                  child: Text(
                    'پیام رمز به‌صورت چند کلمهٔ معمولی فرستاده می‌شود و گوشی '
                    'گیرنده آن را باز می‌کند؛ پیام بلندتر می‌شود و ممکن است پیامک '
                    'بیشتری ببرد.',
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                row(
                  '',
                  'طبق تنظیم «پیام‌های رمز»',
                  subtitle: 'اکنون: ${_coverLabel(state.cover)}',
                ),
                const Divider(height: 1),
                row('off', 'خاموش'),
                row('fa', 'فارسی'),
                row('en', 'انگلیسی'),
                const SizedBox(height: 8),
              ],
            ),
          ),
        );
      },
    );
    if (chosen == null || !mounted) return;
    _bloc.add(
      SecureSetThreadCover(widget.phone, chosen.isEmpty ? null : chosen),
    );
  }

  /// The conversation's own ⋮ — what it can set apart from the inbox menu.
  Widget? _menu(SecureMessagesState state, {required bool encrypted}) {
    final sims = SimService.isMultiSim;
    final cover = kOrganizationBuild && encrypted;
    if (state.status != SecureMessagesStatus.ready || (!sims && !cover)) {
      return null;
    }
    final sim = _sim();
    return PopupMenuButton<String>(
      tooltip: 'گزینه‌های بیشتر',
      onSelected: (v) => v == 'sim' ? _pickSim() : _pickCover(),
      itemBuilder: (_) => [
        if (sims)
          PopupMenuItem(
            value: 'sim',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.sim_card_outlined),
              title: const Text('سیم‌کارت ارسال'),
              subtitle: sim == null
                  ? null
                  : Text(
                      '${sim.slotLabel} · ${sim.name}'
                      '${state.threadSims.containsKey(widget.phone) ? '' : ' (طبق تنظیم کلی)'}',
                    ),
            ),
          ),
        if (cover)
          PopupMenuItem(
            value: 'cover',
            child: ListTile(
              contentPadding: EdgeInsets.zero,
              leading: const Icon(Icons.text_snippet_outlined),
              title: const Text('متن پوششی'),
              subtitle: Text(
                '${_coverLabel(state.coverFor(widget.phone))}'
                '${state.threadCovers.containsKey(widget.phone) ? '' : ' (طبق تنظیم کلی)'}',
              ),
            ),
          ),
      ],
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
                message: 'این گفتگو داخل بخش امن است. بخش امن را باز کنید.',
              ),
            );
          }
          final messages = state.openPhone == widget.phone
              ? state.openMessages
              : const <SecureMessage>[];
          // A hidden contact's plain-SMS thread (phase G): kept out of the
          // system's message store, and apart from any encrypted chat.
          final encrypted = !SecureMessenger.isPlainThread(widget.phone);
          // The header says «رمزشده» and nothing more: the post-quantum
          // upgrade runs unseen in the background (owner, 1405/07/29). What
          // the user must act on — a channel that did not come — is a
          // banner below.
          final channel = _channel(state);
          final menu = _menu(state, encrypted: encrypted);
          return Scaffold(
            appBar: RtlAppBar(
              actions: [?menu],
              titleWidget: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  // The name as the store has it now: the screen may have
                  // been opened before the conversation was listed.
                  Text(
                    state.names[widget.phone] ?? widget.name,
                    style: const TextStyle(fontSize: 18),
                  ),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        encrypted ? Icons.lock : Icons.lock_open,
                        size: 12,
                        color: encrypted ? scheme.primary : scheme.error,
                      ),
                      const SizedBox(width: 4),
                      Text(
                        encrypted ? 'رمزشده' : 'پیامک رمزنشده',
                        style: TextStyle(
                          fontSize: 12,
                          color: encrypted ? scheme.primary : scheme.error,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            body: Column(
              children: [
                if (!encrypted)
                  SecureBanner(
                    icon: Icons.lock_open,
                    text:
                        'پیامک‌های رمزنشدهٔ این مخاطب مخفی؛ در سوابق گوشی ثبت '
                        'نمی‌شوند. پیام رمز به او در گفتگوی جداگانهٔ «پیام‌های '
                        'رمز» است.',
                  ),
                if (channel == _Channel.connecting)
                  SecureBanner(
                    icon: Icons.sync_lock,
                    text:
                        'در حال برقراری کانال امن. پیام‌ها پس از پاسخ گوشی مقابل '
                        'ارسال می‌شوند.',
                  ),
                if (channel == _Channel.requestFailed)
                  SecureBanner(
                    icon: Icons.error_outline,
                    error: true,
                    text:
                        'پیامک درخواست کانال امن ارسال نشد. اعتبار و آنتن '
                        'سیم‌کارتی را که پیام رمز با آن می‌رود بررسی کنید '
                        '(منوی «پیام‌های رمز» ← سیم‌کارت) و دوباره تلاش کنید.',
                    action: 'دوباره تلاش',
                    onAction: () => _bloc.add(SecureRetryChannel(widget.phone)),
                  ),
                if (channel == _Channel.noAnswer)
                  SecureBanner(
                    icon: Icons.hourglass_bottom,
                    text:
                        'پاسخی از گوشی مقابل نرسیده. اگر این شماره هم‌رسانِ '
                        'دارای کلید سازمانی نداشته باشد، پیام‌ها به دستش '
                        'نمی‌رسد؛ اگر دارد، شاید گوشی‌اش خاموش یا بی‌آنتن است. '
                        'پیام‌ها تا برقراری کانال در صف می‌مانند.',
                    action: 'دوباره تلاش',
                    onAction: () => _bloc.add(SecureRetryChannel(widget.phone)),
                  ),
                Expanded(
                  child: messages.isEmpty
                      ? Center(
                          child: Padding(
                            padding: const EdgeInsets.all(32),
                            child: Text(
                              encrypted
                                  ? 'پیام‌های این گفتگو با کلیدی که فقط شما دو '
                                        'نفر دارید رمز می‌شوند.'
                                  : 'این گفتگو فقط داخل بخش امن دیده می‌شود.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: scheme.onSurfaceVariant),
                            ),
                          ),
                        )
                      // Reversed, so the list's end is the top: scrolling up
                      // to the oldest loaded message reads the page before it.
                      : InfiniteScroll(
                          hasMore: state.openHasMore,
                          onLoadMore: () => context
                              .read<SecureMessagesBloc>()
                              .add(const SecureLoadOlder()),
                          child: ListView.builder(
                            reverse: true,
                            padding: const EdgeInsets.fromLTRB(12, 12, 12, 8),
                            itemCount:
                                messages.length + (state.openHasMore ? 1 : 0),
                            itemBuilder: (context, i) => i == messages.length
                                ? const LoadMoreIndicator()
                                : _Bubble(
                                    messages[messages.length - 1 - i],
                                    // In a plain conversation the banner says
                                    // it once; a mark on every bubble is noise.
                                    markPlain: encrypted,
                                  ),
                          ),
                        ),
                ),
                SecureComposer(
                  controller: _controller,
                  plain: !encrypted,
                  expiry: encrypted ? _expiry : SecureExpiry.none,
                  onExpiry: (e) => setState(() => _expiry = e),
                  onSend: _send,
                  sim: _sim,
                  onPickSim: _pickSim,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}

/// A notice above a secure thread, with an optional action («دوباره تلاش»).
class SecureBanner extends StatelessWidget {
  const SecureBanner({
    super.key,
    required this.icon,
    required this.text,
    this.error = false,
    this.action,
    this.onAction,
  });
  final IconData icon;
  final String text;
  final bool error;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bg = error ? scheme.errorContainer : scheme.secondaryContainer;
    final fg = error ? scheme.onErrorContainer : scheme.onSecondaryContainer;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.fromLTRB(12, 8, 12, 0),
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 6),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Row(
            children: [
              Icon(icon, size: 20, color: fg),
              const SizedBox(width: 10),
              Expanded(
                child: Text(text, style: TextStyle(fontSize: 13, color: fg)),
              ),
            ],
          ),
          if (action != null)
            TextButton(
              onPressed: onAction,
              child: Text(action!, style: TextStyle(color: fg)),
            )
          else
            const SizedBox(height: 4),
        ],
      ),
    );
  }
}

class _Bubble extends StatelessWidget {
  const _Bubble(this.m, {required this.markPlain});
  final SecureMessage m;

  /// Label a plain message «رمزنشده» — only where it is the exception.
  final bool markPlain;

  /// The card ours went out on — on a dual-SIM phone, and only when the row
  /// recorded one that is still in the phone (as the ordinary bubble does:
  /// unknown is never «سیم ۱»).
  SimCard? get _sentOn => m.outgoing && m.sim != null && SimService.isMultiSim
      ? SimService.byId(m.sim)
      : null;

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
                  if (m.plain && markPlain) ...[
                    Icon(
                      Icons.lock_open,
                      size: 13,
                      color: fg.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      'رمزنشده',
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
                  if (m.ttl != null) ...[
                    Icon(
                      Icons.av_timer,
                      size: 13,
                      color: fg.withValues(alpha: 0.7),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      SecureExpiry.remaining(m.ttl!, m.expiresAt),
                      style: TextStyle(
                        fontSize: 11,
                        color: fg.withValues(alpha: 0.7),
                      ),
                    ),
                    const SizedBox(width: 6),
                  ],
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
                  if (_sentOn case final sim?) ...[
                    const SizedBox(width: 6),
                    _SimTag(sim),
                  ],
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
              if (_sentOn case final sim?)
                ListTile(
                  enabled: false,
                  leading: const Icon(Icons.sim_card_outlined),
                  title: Text('ارسال‌شده با ${sim.slotLabel}'),
                  subtitle: Text(sim.name),
                ),
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

/// «سیم ۱» under a sent bubble, in the card's colour — the mentor's
/// «ارسال‌شده با سیم‌کارت ۱»; the long-press sheet says it in full.
class _SimTag extends StatelessWidget {
  const _SimTag(this.sim);
  final SimCard sim;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final tint = Color.lerp(
      sim.tint ?? (sim.slotIndex == 0 ? scheme.primary : scheme.tertiary),
      scheme.onPrimaryContainer,
      0.35,
    )!;
    return Semantics(
      label: 'ارسال‌شده با ${sim.slotLabel}',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.sim_card_outlined, size: 12, color: tint),
          const SizedBox(width: 2),
          Text(
            sim.slotLabel,
            style: TextStyle(
              fontSize: 11,
              color: tint,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
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

/// The composer of every secure thread (one-to-one and group). The text
/// never feeds a keyboard's learned words.
/// How a message goes away: «حذف پس از دیدن» (row 20) or a lifetime
/// (row 16, «پیام زمان‌دار»). The sender picks one per message.
@immutable
class SecureExpiry {
  const SecureExpiry._(this.deleteAfterSeen, this.ttl, this.label);

  static const none = SecureExpiry._(false, null, 'بدون پاک شدن خودکار');
  static const afterSeen = SecureExpiry._(true, null, 'پس از دیدن');
  static const choices = [
    none,
    afterSeen,
    SecureExpiry._(false, 30, '۳۰ ثانیه'),
    SecureExpiry._(false, 300, '۵ دقیقه'),
    SecureExpiry._(false, 3600, '۱ ساعت'),
    SecureExpiry._(false, 86400, '۱ روز'),
    SecureExpiry._(false, 604800, '۱ هفته'),
  ];

  final bool deleteAfterSeen;

  /// Seconds; null when the message is not timed.
  final int? ttl;
  final String label;

  bool get isSet => deleteAfterSeen || ttl != null;

  String get notice => deleteAfterSeen
      ? 'این پیام پس از دیده شدن از گوشی گیرنده پاک می‌شود'
      : 'پیام زمان‌دار: $label پس از دیده شدن از گوشی گیرنده و $label '
            'پس از ارسال از این گوشی پاک می‌شود';

  /// A timed bubble's mark: when it goes, or its lifetime while it waits
  /// to be seen.
  static String remaining(int ttl, int? expiresAt) {
    if (expiresAt == null) {
      return choices.where((c) => c.ttl == ttl).firstOrNull?.label ??
          PersianUtils.toPersianNumber('$ttl ثانیه');
    }
    final at = DateTime.fromMillisecondsSinceEpoch(expiresAt);
    return 'تا ${DateFormatter.formatTime(at)}';
  }
}

class SecureComposer extends StatelessWidget {
  const SecureComposer({
    super.key,
    required this.controller,
    required this.plain,
    required this.expiry,
    required this.onExpiry,
    required this.onSend,
    this.hint,
    this.note,
    this.sim,
    this.onPickSim,
  });

  final TextEditingController controller;

  /// A keyless conversation: no «حذف پس از دیدن» and no lifetime (only an
  /// encrypted message can carry them).
  final bool plain;
  final SecureExpiry expiry;
  final ValueChanged<SecureExpiry> onExpiry;
  final VoidCallback onSend;

  /// Overrides the field's hint.
  final String? hint;

  /// A small line under the field (a group's SMS cost).
  final String? note;

  /// The card the next message leaves on (matrix row 5, and the mentor's
  /// «قبل از ارسال، سیم‌کارت انتخاب‌شده نمایش داده شود»): asked when the
  /// chip is drawn, so a roster read late still shows. Dual-SIM only —
  /// [SimChip] draws nothing on a single-SIM phone.
  final SimCard? Function()? sim;

  /// The chip was tapped: choose the card, as the ordinary composer's does.
  final VoidCallback? onPickSim;

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
            if (expiry.isSet)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 6),
                child: Row(
                  children: [
                    Icon(
                      expiry.deleteAfterSeen
                          ? Icons.timer_outlined
                          : Icons.av_timer,
                      size: 16,
                      color: scheme.primary,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        expiry.notice,
                        style: TextStyle(fontSize: 12, color: scheme.primary),
                      ),
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                if (!plain)
                  PopupMenuButton<SecureExpiry>(
                    tooltip: 'پاک شدن خودکار',
                    initialValue: expiry,
                    onSelected: onExpiry,
                    icon: Icon(
                      expiry.isSet ? Icons.timer : Icons.timer_outlined,
                      color: expiry.isSet ? scheme.primary : null,
                    ),
                    itemBuilder: (_) => [
                      for (final c in SecureExpiry.choices)
                        PopupMenuItem(
                          value: c,
                          child: Directionality(
                            textDirection: TextDirection.rtl,
                            child: Text(
                              c == SecureExpiry.none || c.deleteAfterSeen
                                  ? c.label
                                  : 'زمان‌دار: ${c.label}',
                            ),
                          ),
                        ),
                    ],
                  ),
                if (sim != null)
                  SimAware(
                    builder: (context, _, _) => SizedBox(
                      height: 48,
                      child: Center(
                        child: SimChip(sim: sim!(), onTap: onPickSim),
                      ),
                    ),
                  ),
                if (sim != null) const SizedBox(width: 4),
                Expanded(
                  child: TextField(
                    controller: controller,
                    minLines: 1,
                    maxLines: 5,
                    textInputAction: TextInputAction.newline,
                    // The encrypted text must not end up in a keyboard's
                    // learned words: Android's own incognito flag
                    // (IME_FLAG_NO_PERSONALIZED_LEARNING), which Gboard and
                    // the Samsung keyboard honour.
                    //
                    // NOT `enableSuggestions: false`. On Android Flutter turns
                    // that into TYPE_TEXT_VARIATION_VISIBLE_PASSWORD, and a
                    // keyboard treats the field as a password: the Samsung
                    // keyboard drops to a Latin-only layout with no emoji key
                    // (found on the phone), so Persian could not be typed at
                    // all. A keyboard that types into a password field with
                    // key events instead of text hits the engine's
                    // `InputConnectionAdaptor.handleKeyEvent`, which keeps one
                    // UTF-16 unit of each character — half an emoji, the
                    // garbled text the mentor reported.
                    autocorrect: false,
                    enableIMEPersonalizedLearning: false,
                    decoration: InputDecoration(
                      hintText:
                          hint ?? (plain ? 'پیامک (رمزنشده)' : 'پیام رمز'),
                    ),
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
            if (note != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
                child: Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: Text(
                    note!,
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
