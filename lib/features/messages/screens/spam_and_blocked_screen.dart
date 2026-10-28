import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/widgets/selection_app_bar.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_name_cache.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/screens/call_block_rules_page.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/template_wire.dart';
import '../repositories/message_repository.dart';
import 'conversation_screen.dart';

/// «هرزنامه و مسدودشده» — where a blocked conversation goes, Google Messages'
/// «Spam & blocked».
///
/// A blocked number's conversation leaves the inbox and lives here, still
/// readable. Each row offers رفع مسدودی / گزارش هرزنامه / حذف گفتگو, and a
/// long-press selects — with «انتخاب همه» — so a hundred spam senders are
/// unblocked, or have their conversations deleted, in one go (design decision,
/// 1405/07/27). Deleting a conversation deletes its SMS from the phone too
/// (`deleteThreadGlobally`) and keeps the number blocked; «رفع مسدودی» takes
/// the number off the phone's own blocked list as well
/// (`BlockedNumbersRepository`).
///
/// Reported entries lead: «هرزنامه» is what brings anyone here.
class SpamAndBlockedScreen extends StatefulWidget {
  const SpamAndBlockedScreen({super.key, this.messages});

  /// Where the conversations are read from; tests hand in their own.
  final MessageRepository? messages;

  @override
  State<SpamAndBlockedScreen> createState() => _SpamAndBlockedScreenState();
}

class _SpamAndBlockedScreenState extends State<SpamAndBlockedScreen> {
  late final MessageRepository _messages =
      widget.messages ?? MessageRepository();

  /// Per blocked key: the contact name and the newest message. Read in ONE
  /// batch for the whole list — it used to be a contact lookup and a message
  /// query per row, which with a hundred blocked senders was two hundred round
  /// trips every time the page opened.
  Map<String, _BlockedRowDetail> _details = const {};

  /// The keys [_details] was read for; a different set re-reads it.
  Set<String> _detailsFor = const {};
  bool _loadingDetails = false;

  /// A delete was handed to the message bloc; its next inbox emit means the
  /// rows are gone and the details are re-read.
  bool _deletePending = false;

  /// Selected canonical keys; non-empty = selection mode.
  final Set<String> _selected = {};
  bool get _selecting => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    context.read<BlockedNumbersBloc>().add(const LoadBlocked());
  }

  Future<void> _loadDetails(List<BlockedNumberModel> numbers) async {
    final keys = {for (final n in numbers) n.normalized};
    if (_loadingDetails || setEquals(keys, _detailsFor)) return;
    _loadingDetails = true;
    try {
      try {
        await ContactNameCache.read();
      } catch (e) {
        // Unnamed rows still work; the conversations matter more.
        debugPrint('blocked list names unavailable: $e');
      }
      final ids = keys.toList();
      final threads = [
        ...await _messages.getAllThreads(
          restrictToThreadIds: ids,
          includeBlocked: true,
        ),
        ...await _messages.getAllThreads(
          restrictToThreadIds: ids,
          includeBlocked: true,
          archived: true,
        ),
      ];
      final last = {for (final t in threads) t.threadId: t.lastMessage};
      final details = <String, _BlockedRowDetail>{
        for (final n in numbers)
          n.normalized: _BlockedRowDetail(
            contactName: ContactNameCache.lookup(n.phoneNumber)?.name,
            lastMessage: last[n.normalized] == null
                ? null
                : TemplateWire.displayText(last[n.normalized]!),
          ),
      };
      if (!mounted) return;
      setState(() {
        _details = details;
        _detailsFor = keys;
      });
    } catch (e) {
      // The rows still read fine as numbers.
      debugPrint('blocked list details failed: $e');
    } finally {
      _loadingDetails = false;
    }
  }

  String _labelOf(BlockedNumberModel n) {
    final name = _details[n.normalized]?.contactName;
    return (name == null || name.isEmpty)
        ? PersianUtils.displayPhone(PhoneNormalizer.toNational(n.phoneNumber))
        : name;
  }

  void _toggle(String key) {
    HapticFeedback.selectionClick();
    setState(() {
      if (!_selected.remove(key)) _selected.add(key);
    });
  }

  void _startSelection(String key) {
    HapticFeedback.mediumImpact();
    setState(() => _selected.add(key));
  }

  void _unblock(List<BlockedNumberModel> numbers) {
    if (numbers.isEmpty) return;
    final bloc = context.read<BlockedNumbersBloc>();
    bloc.add(UnblockNumbers([for (final n in numbers) n.normalized]));
    setState(_selected.clear);
    // Bringing the conversations back into the inbox is the inbox's own job:
    // it listens for the blocked set changing.
    showUndoSnack(
      context,
      message: numbers.length == 1
          ? '«${_labelOf(numbers.single)}» از مسدودی خارج شد'
          : '${PersianUtils.toPersianNumber('${numbers.length}')} شماره از مسدودی خارج شد',
      onUndo: () {
        for (final n in numbers) {
          bloc.add(BlockNumber(n.phoneNumber, report: n.isSpam));
        }
      },
    );
  }

  /// Deletes the conversations of [numbers] from the phone; the numbers stay
  /// blocked. Asked first — it cannot be undone.
  Future<void> _deleteConversations(List<BlockedNumberModel> numbers) async {
    final withConversation = [
      for (final n in numbers)
        if (_details[n.normalized]?.lastMessage != null) n,
    ];
    if (withConversation.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('گفتگویی برای حذف نیست')));
      return;
    }
    final count = PersianUtils.toPersianNumber('${withConversation.length}');
    final one = withConversation.length == 1;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text(one ? 'گفتگو حذف شود؟' : '$count گفتگو حذف شود؟'),
          content: Text(
            one
                ? 'پیامک‌های این گفتگو از گوشی پاک می‌شوند و برنمی‌گردند. '
                      'شماره مسدود می‌ماند.'
                : 'پیامک‌های این گفتگوها از گوشی پاک می‌شوند و برنمی‌گردند. '
                      'شماره‌ها مسدود می‌مانند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(dialogContext, true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;
    _deletePending = true;
    context.read<MessageBloc>().add(
      DeleteThreads([for (final n in withConversation) n.normalized]),
    );
    setState(_selected.clear);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(one ? 'گفتگو حذف شد' : '$count گفتگو حذف شد')),
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

  List<BlockedNumberModel> _selectedIn(BlockedNumbersState state) => [
    if (state is BlockedNumbersLoaded)
      for (final n in state.numbers)
        if (_selected.contains(n.normalized)) n,
  ];

  PreferredSizeWidget _appBar(BlockedNumbersState state) {
    if (!_selecting) {
      return RtlAppBar(
        title: 'هرزنامه و مسدودشده',
        actions: [
          IconButton(
            icon: const Icon(Icons.add),
            tooltip: 'افزودن شماره',
            onPressed: _addNumber,
          ),
        ],
      );
    }
    final all = state is BlockedNumbersLoaded
        ? {for (final n in state.numbers) n.normalized}
        : const <String>{};
    return SelectionAppBar(
      selectedCount: _selected.length,
      onClear: () => setState(_selected.clear),
      actions: [
        IconButton(
          icon: const Icon(Icons.select_all),
          tooltip: 'انتخاب همه',
          onPressed: _selected.length == all.length
              ? null
              : () => setState(() => _selected.addAll(all)),
        ),
        IconButton(
          icon: const Icon(Icons.do_not_disturb_off_outlined),
          tooltip: 'رفع مسدودی',
          onPressed: () => _unblock(_selectedIn(state)),
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'حذف گفتگو',
          onPressed: () => _deleteConversations(_selectedIn(state)),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return BlocListener<MessageBloc, MessageState>(
      // The inbox reloads after a delete; that reload is the moment the rows
      // are gone, so the details are read again then.
      listenWhen: (_, next) => _deletePending && next is ThreadsLoaded,
      listener: (_, _) {
        _deletePending = false;
        setState(() => _detailsFor = const {});
      },
      child: BlocBuilder<BlockedNumbersBloc, BlockedNumbersState>(
        builder: (context, state) {
          if (state is BlockedNumbersLoaded) _loadDetails(state.numbers);
          // A number unblocked elsewhere (or by an undo) must not stay
          // selected behind the bar's count.
          final live = state.blockedKeys;
          if (_selected.any((k) => !live.contains(k))) {
            _selected.removeWhere((k) => !live.contains(k));
          }
          return Directionality(
            textDirection: TextDirection.rtl,
            child: PopScope(
              // Back leaves the selection first, as everywhere in the app.
              canPop: !_selecting,
              onPopInvokedWithResult: (didPop, _) {
                if (!didPop) setState(_selected.clear);
              },
              child: Scaffold(
                appBar: _appBar(state),
                // The call rules sit above the list — see [_CallRulesRow].
                body: Column(
                  children: [
                    // Kept in place while selecting — removing it moved the
                    // list up under the finger that had just long-pressed —
                    // but inert and dimmed, so the bar's actions are about
                    // the list.
                    IgnorePointer(
                      ignoring: _selecting,
                      child: AnimatedOpacity(
                        opacity: _selecting ? 0.38 : 1,
                        duration: const Duration(milliseconds: 150),
                        child: const _CallRulesRow(),
                      ),
                    ),
                    Expanded(child: _buildList(context, state)),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  Widget _buildList(BuildContext context, BlockedNumbersState state) {
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
            'تماس‌ها و پیامک‌های این شماره‌ها در همهٔ گوشی رد می‌شوند و '
            'گفتگویشان از صندوق پیام‌ها بیرون است. برای انتخاب چند شماره، '
            'یکی را نگه دارید.',
            style: Theme.of(context).textTheme.bodySmall,
          ),
        ),
        if (spam.isNotEmpty) ...[
          const SectionLabel('هرزنامه'),
          GroupedList(children: [for (final n in spam) _row(n)]),
        ],
        if (blocked.isNotEmpty) ...[
          const SectionLabel('مسدودشده'),
          GroupedList(children: [for (final n in blocked) _row(n)]),
        ],
      ],
    );
  }

  Widget _row(BlockedNumberModel number) {
    final detail = _details[number.normalized];
    final label = _labelOf(number);
    return _BlockedRow(
      key: ValueKey(number.normalized),
      number: number,
      label: label,
      detail: detail,
      selecting: _selecting,
      selected: _selected.contains(number.normalized),
      onTap: _selecting
          ? () => _toggle(number.normalized)
          : () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ConversationScreen.forPhone(
                  number.phoneNumber,
                  contactName: detail?.contactName,
                ),
              ),
            ),
      onLongPress: () => _selecting
          ? _toggle(number.normalized)
          : _startSelection(number.normalized),
      onUnblock: () => _unblock([number]),
      onDelete: () => _deleteConversations([number]),
      onToggleReport: () {
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

  /// Null when the number has no conversation.
  final String? lastMessage;
  const _BlockedRowDetail({this.contactName, this.lastMessage});
}

class _BlockedRow extends StatelessWidget {
  const _BlockedRow({
    super.key,
    required this.number,
    required this.label,
    required this.detail,
    required this.selecting,
    required this.selected,
    required this.onTap,
    required this.onLongPress,
    required this.onUnblock,
    required this.onDelete,
    required this.onToggleReport,
  });

  final BlockedNumberModel number;

  /// The contact's name, or the formatted number.
  final String label;
  final _BlockedRowDetail? detail;
  final bool selecting;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback onLongPress;
  final VoidCallback onUnblock;
  final VoidCallback onDelete;
  final VoidCallback onToggleReport;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final display = PersianUtils.displayPhone(
      PhoneNormalizer.toNational(number.phoneNumber),
    );
    final named = label != display;
    final preview = detail?.lastMessage;
    final hasConversation = preview != null;

    return ListTile(
      selected: selected,
      leading: selecting
          ? SizedBox(
              width: 44,
              height: 44,
              child: Center(child: SelectionCheck(selected: selected)),
            )
          : PhoneContactAvatar(
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
        hasConversation && preview.isNotEmpty
            ? preview.replaceAll('\n', ' ')
            : (named ? display : 'بدون گفتگو'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: theme.textTheme.bodySmall,
      ),
      trailing: selecting
          ? null
          : PopupMenuButton<String>(
              onSelected: (value) => switch (value) {
                'unblock' => onUnblock(),
                'report' => onToggleReport(),
                'delete' => onDelete(),
                _ => null,
              },
              itemBuilder: (_) => [
                const PopupMenuItem(
                  value: 'unblock',
                  child: Text('رفع مسدودی'),
                ),
                PopupMenuItem(
                  value: 'report',
                  child: Text(
                    number.isSpam ? 'این هرزنامه نیست' : 'گزارش هرزنامه',
                  ),
                ),
                if (hasConversation)
                  const PopupMenuItem(
                    value: 'delete',
                    child: Text('حذف گفتگو'),
                  ),
              ],
            ),
      // The conversation stays readable — Google keeps blocked messages, it
      // just stops surfacing them. Opening it does not unblock anything.
      onTap: onTap,
      onLongPress: onLongPress,
    );
  }
}

/// «مسدود کردن تماس» — the rules that refuse a call by what kind of caller it
/// is (no caller id, not a contact, foreign, advertising prefix), one row that
/// opens [CallBlockRulesPage].
///
/// Above the list and outside its BlocBuilder on purpose: a rule is not an
/// entry — there is no number to list for a caller who withheld theirs — and
/// it has to be reachable on the empty state, which is exactly when somebody
/// comes here looking for it. Google Phone puts its «Unknown» switch in the
/// same place. The switches themselves moved to their own page when there
/// came to be four of them: in a column above a list they left the list no
/// room.
class _CallRulesRow extends StatelessWidget {
  const _CallRulesRow();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<SettingsBloc, SettingsState>(
      builder: (context, state) {
        final active = [
          state.blockUnknownCallers,
          state.blockNonContacts,
          state.blockInternational,
          state.blockAdvertising,
        ].where((on) => on).length;
        return Padding(
          padding: const EdgeInsets.only(top: 4),
          child: GroupedList(
            children: [
              SettingsRow(
                icon: Icons.phone_disabled_outlined,
                title: 'مسدود کردن تماس',
                summary: active == 0
                    ? 'ناشناس، خارج از مخاطبین، بین‌المللی، تبلیغاتی'
                    : '${PersianUtils.toPersianNumber('$active')} قانون فعال',
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CallBlockRulesPage()),
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}
