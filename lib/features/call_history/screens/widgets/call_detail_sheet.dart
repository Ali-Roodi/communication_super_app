import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/infinite_scroll.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_state.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/screens/widgets/call_log_tile.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/save_number_actions.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/messages/models/message_model.dart';
import 'package:communication_super_app/features/messages/repositories/message_repository.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/messages/models/template_wire.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';

/// Call detail bottom sheet — opened from the ⓘ icon on a recents row.
///
/// Header (avatar, name, number) + action chips, followed by the breakdown of
/// every call with this number in the currently-loaded history, then copy /
/// block actions.
Future<void> showCallDetailSheet(
  BuildContext context,
  CallLogModel log, {
  int count = 1,
  List<String>? groupIds,
}) {
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
    builder: (_) => _CallDetailSheet(
      log: log,
      calls: calls,
      count: count,
      groupIds: groupIds,
      // The page underneath. Actions that dismiss the sheet and then need a
      // dialog or a snack bar have to run against a context that outlives it —
      // the sheet's own context is dead the moment it pops.
      pageContext: context,
    ),
  );
}

/// «ویرایش مخاطب»: closes the sheet, resolves the person by number and opens
/// the editor on the page underneath — the sheet's own context is dead the
/// moment it pops.
///
/// A SIM (ADN) record has no ContactsContract row to edit; its detail page
/// offers «کپی در تلفن» instead, which is where the user is sent.
Future<void> _editContact(BuildContext sheetContext, String number) async {
  final pageContext = Navigator.of(sheetContext).context;
  final callLogBloc = sheetContext.read<CallLogBloc>();
  Navigator.of(sheetContext).pop();
  final match = await ContactRepository().getContactByPhoneNumber(number);
  if (!pageContext.mounted) return;
  if (match == null) {
    ScaffoldMessenger.of(pageContext).showSnackBar(
      const SnackBar(content: Text('مخاطب در دفترچه تلفن پیدا نشد')),
    );
    return;
  }
  if (match.isSimContact) {
    await Navigator.of(pageContext).push(
      MaterialPageRoute(
        builder: (_) => DeviceContactDetailScreen(contact: match),
      ),
    );
    callLogBloc.add(const RefreshCallLogs());
    return;
  }
  final saved = await Navigator.of(pageContext).push<bool>(
    MaterialPageRoute(
      builder: (_) => AddEditContactScreen(contactId: match.id),
    ),
  );
  if (saved == true) callLogBloc.add(const RefreshCallLogs());
}

class _CallDetailSheet extends StatelessWidget {
  final CallLogModel log;
  final List<CallLogModel> calls;

  /// Number of collapsed calls in the row this sheet was opened from, and the
  /// IDs to delete — mirrors [CallLogTile.count] / [CallLogTile.groupIds].
  final int count;
  final List<String>? groupIds;

  /// The page the sheet was opened from — see [showCallDetailSheet].
  final BuildContext pageContext;

  const _CallDetailSheet({
    required this.log,
    required this.calls,
    required this.pageContext,
    this.count = 1,
    this.groupIds,
  });

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
          // A sliver view so the history below the actions is built lazily
          // and pages in as it scrolls; shrink-wrapped so a short history
          // still yields a short sheet.
          child: CustomScrollView(
            shrinkWrap: true,
            slivers: [
              SliverToBoxAdapter(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const SizedBox(height: 4),
                    PhoneContactAvatar(
                      phoneNumber: log.phoneNumber,
                      name: displayName,
                      size: 80,
                    ),
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
                            color: theme.textTheme.bodyMedium?.color
                                ?.withValues(alpha: 0.7),
                          ),
                        ),
                      ),
                    ],
                    const SizedBox(height: 20),
                    _ActionChips(log: log, hasName: hasName),
                    const SizedBox(height: 12),
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
                    // «تماس با سیم ۱» / «تماس با سیم ۲» — Google Phone lists
                    // these here, and they are what reaches the non-default card
                    // without touching an Android setting. Absent on one SIM.
                    ...simCallRows(
                      pageContext,
                      log.phoneNumber,
                      onBeforeCall: () => Navigator.of(context).pop(),
                    ),
                    // Keeping the number, and reaching the person behind it: the
                    // same pair Google Phone lists in its «Call details» sheet.
                    // «افزودن به مخاطب موجود» is the one that was missing, and it
                    // is the more common of the two.
                    if (hasName)
                      ListTile(
                        leading: const Icon(Icons.edit_outlined),
                        title: const Text('ویرایش مخاطب'),
                        onTap: () => _editContact(context, log.phoneNumber),
                      )
                    else
                      ListTile(
                        leading: const Icon(Icons.person_search_outlined),
                        title: const Text('افزودن به مخاطب موجود'),
                        onTap: () {
                          final callLogBloc = context.read<CallLogBloc>();
                          Navigator.of(context).pop();
                          addNumberToExistingContact(
                            pageContext,
                            log.phoneNumber,
                          ).then((saved) {
                            if (saved) callLogBloc.add(const RefreshCallLogs());
                          });
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
                        'مسدود کردن و گزارش هرزنامه',
                        style: TextStyle(color: AppColors.callRejectRed),
                      ),
                      onTap: () {
                        // The sheet closes first, and the confirmation runs against
                        // the page underneath: the dialog and its undo snack bar
                        // both have to outlive this route.
                        Navigator.of(context).pop();
                        blockNumberWithConfirm(
                          pageContext,
                          phoneNumber: log.phoneNumber,
                          contactName: log.contactName,
                        );
                      },
                    ),
                    ListTile(
                      leading: const Icon(
                        Icons.delete_outline,
                        color: AppColors.callRejectRed,
                      ),
                      title: Text(
                        count > 1
                            ? 'حذف (${PersianUtils.toPersianNumber('$count')} تماس)'
                            : 'حذف',
                        style: const TextStyle(color: AppColors.callRejectRed),
                      ),
                      onTap: () {
                        context.read<CallLogBloc>().add(
                          DeleteCallLogs(groupIds ?? [log.id]),
                        );
                        Navigator.of(context).pop();
                      },
                    ),
                    // The history goes last: it pages without end, and the
                    // actions above must not drift out of reach as it grows.
                    const Divider(height: 1),
                  ],
                ),
              ),
              // ── Activity log: calls + SMS, newest first ──────────
              _ActivityLog(seed: calls, phoneNumber: log.phoneNumber),
            ],
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
              // The ordinary rules, this call's card only as the picker's
              // hint — see [CallLogTile].
              onTap: () {
                Navigator.of(context).pop();
                placeCall(context, log.phoneNumber, suggested: log.sim);
              },
              onLongPress: SimService.isMultiSim
                  ? () {
                      Navigator.of(context).pop();
                      placeCallPickingSim(context, log.phoneNumber);
                    }
                  : null,
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
                  // Indexed lookup — see ContactRepository._numberLookup.
                  final match = await ContactRepository()
                      .getContactByPhoneNumber(log.phoneNumber);
                  navigator.pop();
                  if (match != null) {
                    navigator.push(
                      MaterialPageRoute(
                        builder: (_) =>
                            DeviceContactDetailScreen(contact: match),
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

  /// Long-press shortcut — «تماس» uses it to pick the SIM for one call.
  final VoidCallback? onLongPress;

  const _ActionChip({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
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
        onLongPress: onLongPress,
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

/// The per-number breakdown: every call AND every SMS exchanged with this
/// number, merged into one newest-first timeline and read from SQLite a page
/// of each at a time as the sheet scrolls.
///
/// Two sources paged separately cannot simply be concatenated: below the
/// oldest row of the source that still has pages, the other source's next
/// page may interleave. So only rows at or after that cut are shown, and the
/// rest appear once the lagging source has caught up.
class _ActivityLog extends StatefulWidget {
  /// What the open «اخیر» page already holds for this number — the first
  /// paint, so the sheet does not open on an empty history.
  final List<CallLogModel> seed;
  final String phoneNumber;

  const _ActivityLog({required this.seed, required this.phoneNumber});

  @override
  State<_ActivityLog> createState() => _ActivityLogState();
}

class _ActivityLogState extends State<_ActivityLog> {
  static const int _page = 30;

  final _calls = <CallLogModel>[];
  final _messages = <MessageModel>[];
  bool _callsMore = true;
  bool _messagesMore = true;
  bool _loading = false;
  bool _loadedOnce = false;
  late final String _threadId = PhoneNormalizer.toThreadId(widget.phoneNumber);

  bool get _hasMore => _callsMore || _messagesMore;

  @override
  void initState() {
    super.initState();
    _messagesMore = _threadId.isNotEmpty;
    _loadMore();
  }

  Future<void> _loadMore() async {
    if (_loading || !_hasMore) return;
    _loading = true;
    try {
      final results = await Future.wait([
        _callsMore
            ? CallLogRepository().getCallLogsForNumber(
                widget.phoneNumber,
                limit: _page,
                offset: _calls.length,
              )
            : Future.value(const <CallLogModel>[]),
        _messagesMore
            ? MessageRepository().getMessagesByThread(
                _threadId,
                limit: _page,
                offset: _messages.length,
                orderDesc: true,
              )
            : Future.value(const <MessageModel>[]),
      ]);
      if (!mounted) return;
      final calls = results[0] as List<CallLogModel>;
      final messages = results[1] as List<MessageModel>;
      setState(() {
        _calls.addAll(calls);
        _messages.addAll(messages);
        if (_callsMore) _callsMore = calls.length == _page;
        if (_messagesMore) _messagesMore = messages.length == _page;
        _loadedOnce = true;
      });
    } catch (e) {
      // A failed read must not become a retry every frame from the end row.
      debugPrint('call detail history page failed: $e');
      if (mounted) {
        setState(() {
          _callsMore = false;
          _messagesMore = false;
          _loadedOnce = true;
        });
      }
    } finally {
      _loading = false;
    }
  }

  /// The oldest moment both sources are complete down to.
  DateTime? get _cut {
    DateTime? cut;
    void lower(bool more, List<DateTime> stamps) {
      if (!more || stamps.isEmpty) return;
      final oldest = stamps.last;
      if (cut == null || oldest.isAfter(cut!)) cut = oldest;
    }

    lower(_callsMore, [for (final c in _calls) c.timestamp]);
    lower(_messagesMore, [for (final m in _messages) m.timestamp]);
    return cut;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final calls = _loadedOnce ? _calls : widget.seed;
    final cut = _loadedOnce ? _cut : null;
    final items = <(DateTime, Widget)>[
      for (final c in calls) (c.timestamp, _CallRow(call: c, theme: theme)),
      for (final m in _messages)
        (m.timestamp, _SmsRow(message: m, theme: theme)),
    ]..sort((a, b) => b.$1.compareTo(a.$1));
    final shown = cut == null
        ? items
        : items.where((it) => !it.$1.isBefore(cut)).toList();
    final more = !_loadedOnce || _hasMore;
    // The sliver lives inside the sheet's scroll view, so it pages itself:
    // the end row being built — scrolled into the cache extent — asks for the
    // next page, and every page that lands rebuilds it to ask again until
    // the view is full.
    return SliverList.builder(
      itemCount: shown.length + (more ? 1 : 0),
      itemBuilder: (context, i) {
        if (i < shown.length) return shown[i].$2;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) _loadMore();
        });
        return const LoadMoreIndicator();
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
          // A compact template payload is unreadable raw — see TemplateWire.
          TemplateWire.displayText(message.body),
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

/// Canonical form, not a digits-only strip: this is what «تماس‌ها با این
/// مخاطب» filters the loaded history by, and a raw strip missed every call the
/// carrier delivered in a different format.
String _normalize(String phone) => PhoneNormalizer.toNational(phone);

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
