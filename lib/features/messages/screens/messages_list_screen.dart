import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import 'package:communication_super_app/core/navigation/app_route_observer.dart';
import 'package:communication_super_app/core/services/composer_draft_store.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
import 'conversation_screen.dart';
import 'contact_selector_screen.dart';
import 'archived_threads_screen.dart';
import 'drafts_list_screen.dart';
import 'scheduled_messages_screen.dart';
import 'starred_messages_screen.dart';
import 'widgets/thread_tile.dart';
import 'widgets/message_list_states.dart';
import 'widgets/messages_app_bars.dart';
import 'widgets/thread_options_sheet.dart';
import 'widgets/default_sms_banner.dart';
import '../services/native_sms_service.dart';

/// Inbox of conversations — Google Messages style.
///
/// Supports inline search, long-press multi-select (delete / archive / mark
/// read), swipe-to-archive (with undo) and swipe-to-toggle-read, plus a
/// single-thread options sheet (pin, archive, mark read/unread, block, delete).
class MessagesListScreen extends StatefulWidget {
  const MessagesListScreen({super.key});

  @override
  State<MessagesListScreen> createState() => _MessagesListScreenState();
}

class _MessagesListScreenState extends State<MessagesListScreen>
    with WidgetsBindingObserver, RouteAware {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _searching = false;
  String _query = '';
  final Set<String> _selected = {};

  final ComposerDraftStore _draftStore = ComposerDraftStore();
  Map<String, ComposerDraft> _drafts = {};

  /// Default-SMS-app banner: shown while the app doesn't hold the SMS role
  /// (full two-way sync requires it). Dismissal lasts for the session.
  final NativeSmsService _nativeSms = NativeSmsService();
  bool _showDefaultSmsBanner = false;
  bool _bannerDismissed = false;

  bool get _selectionMode => _selected.isNotEmpty;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_hasLoadedInitially) {
        _hasLoadedInitially = true;
        context.read<MessageBloc>().add(const LoadThreads());
      }
    });
    WidgetsBinding.instance.addObserver(this);
    _scrollController.addListener(_onScroll);
    _loadDrafts();
    _checkDefaultSmsApp();
  }

  Future<void> _checkDefaultSmsApp() async {
    final isDefault = await _nativeSms.isDefaultSmsApp();
    if (!mounted) return;
    setState(() => _showDefaultSmsBanner = !isDefault && !_bannerDismissed);
  }

  /// Fire-and-forget re-check used from build while the banner is visible:
  /// the user may have granted the role from system Settings without the app
  /// ever pausing (e.g. split screen) or while on another tab. Only ever
  /// *hides* the banner, so it cannot rebuild-loop.
  bool _recheckingDefault = false;
  Future<void> _recheckDefaultSilently() async {
    if (_recheckingDefault) return;
    _recheckingDefault = true;
    final isDefault = await _nativeSms.isDefaultSmsApp();
    _recheckingDefault = false;
    if (mounted && isDefault && _showDefaultSmsBanner) {
      setState(() => _showDefaultSmsBanner = false);
    }
  }

  Future<void> _requestDefaultSmsRole() async {
    final granted = await _nativeSms.requestDefaultSmsRole();
    if (!mounted) return;
    setState(() => _showDefaultSmsBanner = !granted && !_bannerDismissed);
    if (granted) {
      // Role granted: mirror-sync immediately so the provider write-through
      // and global deletes take effect from now on.
      context.read<MessageBloc>().add(const SyncDeviceMessages());
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('این برنامه پیام‌رسان پیش‌فرض شد')),
      );
    } else {
      // Denied — or the system auto-denied (it does after two refusals).
      // Offer the manual path: Settings → Default apps.
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text(
            'درخواست رد شد. می‌توانید از تنظیمات، برنامه‌های پیش‌فرض را '
            'تغییر دهید',
          ),
          action: SnackBarAction(
            label: 'تنظیمات',
            onPressed: () => _nativeSms.openDefaultAppsSettings(),
          ),
        ),
      );
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  /// Called when a route pushed above the inbox is popped (e.g. returning from a
  /// conversation opened via the "new message" flow). Refresh threads + drafts.
  @override
  void didPopNext() {
    if (!mounted) return;
    context.read<MessageBloc>().add(const LoadThreads());
    _loadDrafts();
  }

  /// Loads the per-thread composer drafts shown as «پیش‌نویس» rows on top.
  Future<void> _loadDrafts() async {
    final drafts = await _draftStore.loadAll();
    if (mounted) setState(() => _drafts = drafts);
  }

  void _onScroll() {
    if (!mounted) return;
    final state = context.read<MessageBloc>().state;
    if (state is! ThreadsLoaded || !state.hasMore) return;
    final pos = _scrollController.position;
    if (pos.pixels >= pos.maxScrollExtent - 200) {
      context.read<MessageBloc>().add(const LoadMoreThreads());
    }
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _searchController.dispose();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && mounted && _hasLoadedInitially) {
      context.read<MessageBloc>().add(const LoadThreads());
      _loadDrafts();
      // The user may have changed the default SMS app in system settings.
      _checkDefaultSmsApp();
    }
  }

  /// Overlays composer drafts onto the thread list: existing threads get a draft
  /// preview, drafts to new numbers become synthetic rows, and rows with a fresh
  /// draft float to the top (pinned rows still lead).
  List<MessageThread> _mergeDrafts(List<MessageThread> threads) {
    if (_drafts.isEmpty) return threads;
    final existing = {for (final t in threads) t.threadId};
    final merged = <MessageThread>[
      for (final t in threads)
        _drafts.containsKey(t.threadId)
            ? t.copyWith(
                draftText: _drafts[t.threadId]!.text,
                draftTime: _drafts[t.threadId]!.updatedAt,
              )
            : t,
    ];
    for (final e in _drafts.entries) {
      if (existing.contains(e.key)) continue;
      final d = e.value;
      merged.add(
        MessageThread(
          threadId: e.key,
          phoneNumber: d.phoneNumber.isNotEmpty ? d.phoneNumber : e.key,
          contactName: d.contactName,
          lastMessage: '',
          lastMessageTime: d.updatedAt,
          draftText: d.text,
          draftTime: d.updatedAt,
        ),
      );
    }
    merged.sort((a, b) {
      if (a.isPinned != b.isPinned) return a.isPinned ? -1 : 1;
      return b.sortTime.compareTo(a.sortTime);
    });
    return merged;
  }

  // ── Selection helpers ───────────────────────────────────────────────────

  void _toggleSelect(String threadId) {
    setState(() {
      if (!_selected.remove(threadId)) _selected.add(threadId);
    });
  }

  void _clearSelection() => setState(_selected.clear);

  List<MessageThread> _visibleThreads(List<MessageThread> all) {
    if (_query.isEmpty) return all;
    final q = _query.toLowerCase();
    return all.where((t) {
      final name = (t.contactName ?? '').toLowerCase();
      final phone = t.phoneNumber.toLowerCase();
      final body = t.lastMessage.toLowerCase();
      return name.contains(q) || phone.contains(q) || body.contains(q);
    }).toList();
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_showDefaultSmsBanner) _recheckDefaultSilently();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        // Google Messages has no app bar: the header is a collapsing sliver and
        // the conversations sit on a rounded sheet that scrolls up under it.
        body: CustomScrollView(
          controller: _scrollController,
          slivers: [
            _buildAppBar(context),
            if (_showDefaultSmsBanner && !_selectionMode && !_searching)
              SliverToBoxAdapter(
                child: DefaultSmsBanner(
                  onRequest: _requestDefaultSmsRole,
                  onDismiss: () => setState(() {
                    _bannerDismissed = true;
                    _showDefaultSmsBanner = false;
                  }),
                ),
              ),
            ..._buildBodySlivers(context),
          ],
        ),
        floatingActionButton: _selectionMode || _searching
            ? null
            : FloatingActionButton.extended(
                heroTag: 'messages_fab',
                onPressed: () async {
                  final messageBloc = context.read<MessageBloc>();
                  await Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (_) => const ContactSelectorScreen(),
                    ),
                  );
                  messageBloc.add(const LoadThreads());
                  _loadDrafts();
                },
                icon: const Icon(Icons.edit_outlined),
                label: const Text('پیام جدید'),
              ),
      ),
    );
  }

  /// The conversation sheet: a rounded surface that the whole list sits on
  /// (Google Messages' «صندوق» plane).
  List<Widget> _buildBodySlivers(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return [
      BlocConsumer<MessageBloc, MessageState>(
        listener: (context, state) {
          if (state is MessageSent || state is MessageSendFailed) {
            context.read<MessageBloc>().add(const LoadThreads());
          }
        },
        builder: (context, state) {
          Widget filler(Widget child) => SliverFillRemaining(
            hasScrollBody: false,
            child: child,
          );

          if (state is MessageLoading ||
              state is MessageInitial ||
              state is MessagesLoaded ||
              state is MessageSent ||
              state is MessageSendFailed) {
            return filler(const Center(child: CircularProgressIndicator()));
          }
          if (state is MessageError) {
            return filler(
              MessagesErrorState(
                message: state.message,
                onRetry: () => context.read<MessageBloc>().add(
                  const LoadThreads(forceRefresh: true),
                ),
              ),
            );
          }
          if (state is! ThreadsLoaded) {
            return filler(const Center(child: CircularProgressIndicator()));
          }
          // The archived view is shown on its own screen; ignore that state
          // here (it only briefly appears while that screen is pushed).
          if (state.archived) {
            return filler(const Center(child: CircularProgressIndicator()));
          }

          final base = _visibleThreads(state.threads);
          final threads = _query.isEmpty ? _mergeDrafts(base) : base;
          if (threads.isEmpty) {
            return filler(
              _query.isEmpty
                  ? const MessagesEmptyState()
                  : const MessagesNoResults(),
            );
          }

          // Rows that exist only because of a draft (no real messages yet).
          final realIds = {for (final t in state.threads) t.threadId};
          return DecoratedSliver(
            decoration: BoxDecoration(
              color: scheme.cardSurface,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(28),
              ),
            ),
            sliver: SliverPadding(
              padding: const EdgeInsets.only(top: 8, bottom: 96),
              sliver: SliverList.builder(
                itemCount: threads.length + (state.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (state.hasMore && index == threads.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final thread = threads[index];
                  final draftOnly =
                      thread.hasDraft && !realIds.contains(thread.threadId);
                  return _buildThreadRow(context, thread, draftOnly: draftOnly);
                },
              ),
            ),
          );
        },
      ),
    ];
  }

  // ── App bars ───────────────────────────────────────────────────────────

  Widget _buildAppBar(BuildContext context) {
    if (_selectionMode) {
      return MessagesSelectionAppBar(
        selectedCount: _selected.length,
        onClear: _clearSelection,
        onMarkRead: () => _setSelectedRead(read: true),
        onArchive: _archiveSelected,
        onDelete: () => _confirmDeleteSelected(context),
        onSelectAll: _selectAllVisible,
        onMarkUnread: () => _setSelectedRead(read: false),
        onBlock: _blockSelected,
        onPin: _pinSelected,
      );
    }
    if (_searching) {
      return MessagesSearchAppBar(
        controller: _searchController,
        showClear: _query.isNotEmpty,
        onBack: () => setState(() {
          _searching = false;
          _query = '';
          _searchController.clear();
        }),
        onClear: () => setState(() {
          _query = '';
          _searchController.clear();
        }),
        onChanged: (v) => setState(() => _query = v),
      );
    }
    return MessagesDefaultAppBar(
      onSearch: () => setState(() => _searching = true),
      onOpenArchived: _openArchived,
      onOpenDrafts: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DraftsListScreen()),
      ),
      onOpenScheduled: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ScheduledMessagesScreen()),
      ),
      onOpenStarred: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const StarredMessagesScreen()),
      ),
      onOpenSettings: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const SettingsScreen()),
      ),
    );
  }

  // ── Selection actions (wired to the selection app bar) ───────────────────

  void _setSelectedRead({required bool read}) {
    context.read<MessageBloc>().add(
      SetThreadRead(_selected.toList(), read: read),
    );
    _clearSelection();
  }

  /// Pins every selected thread that isn't pinned yet; if they all already are,
  /// the action unpins them (Google's toggle behaviour on a mixed selection is
  /// "make them all pinned first").
  void _pinSelected() {
    final state = context.read<MessageBloc>().state;
    final all = state is ThreadsLoaded
        ? state.threads
        : const <MessageThread>[];
    final chosen = all.where((t) => _selected.contains(t.threadId)).toList();
    if (chosen.isEmpty) {
      _clearSelection();
      return;
    }
    final pin = chosen.any((t) => !t.isPinned);
    final bloc = context.read<MessageBloc>();
    for (final t in chosen) {
      if (t.isPinned != pin) bloc.add(PinThread(t.threadId, pin: pin));
    }
    _clearSelection();
  }

  void _archiveSelected() {
    context.read<MessageBloc>().add(
      ArchiveThreads(_selected.toList(), archive: true),
    );
    _clearSelection();
  }

  void _selectAllVisible() {
    final state = context.read<MessageBloc>().state;
    final all = state is ThreadsLoaded
        ? state.threads
        : const <MessageThread>[];
    setState(() {
      _selected
        ..clear()
        ..addAll(_visibleThreads(all).map((t) => t.threadId));
    });
  }

  void _blockSelected() {
    final state = context.read<MessageBloc>().state;
    final all = state is ThreadsLoaded
        ? state.threads
        : const <MessageThread>[];
    final blockedBloc = context.read<BlockedNumbersBloc>();
    for (final t in all.where((t) => _selected.contains(t.threadId))) {
      blockedBloc.add(BlockNumber(t.phoneNumber));
    }
    _clearSelection();
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('شماره‌ها مسدود شدند')));
  }

  void _openArchived() {
    final bloc = context.read<MessageBloc>();
    Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const ArchivedThreadsScreen()),
    ).then((_) {
      if (mounted) bloc.add(const LoadThreads());
    });
  }

  // ── Thread row (swipe + tile) ────────────────────────────────────────────

  Widget _buildThreadRow(
    BuildContext context,
    MessageThread thread, {
    bool draftOnly = false,
  }) {
    final selected = _selected.contains(thread.threadId);
    final cs = Theme.of(context).colorScheme;

    final tile = ThreadTile(
      thread: thread,
      selected: selected,
      selectionMode: _selectionMode,
      onTap: () {
        if (_selectionMode) {
          _toggleSelect(thread.threadId);
        } else {
          _openConversation(context, thread);
        }
      },
      onLongPress: () {
        if (_selectionMode) {
          _toggleSelect(thread.threadId);
        } else if (draftOnly) {
          _discardDraft(context, thread);
        } else {
          _showThreadOptions(context, thread);
        }
      },
    );

    // «کشیدن برای بایگانی» (Settings → پیامک‌ها) turns the swipe gestures off.
    if (!context.watch<SettingsBloc>().state.swipeActions) return tile;

    // A draft-only row has no conversation to archive / mark read — either swipe
    // simply discards the draft.
    if (draftOnly) {
      return Dismissible(
        key: ValueKey('thread_${thread.threadId}'),
        confirmDismiss: (_) async {
          _discardDraft(context, thread);
          return false;
        },
        background: ThreadSwipeBackground(
          color: cs.error,
          icon: Icons.delete_outline,
          label: 'حذف پیش‌نویس',
          alignStart: true,
        ),
        secondaryBackground: ThreadSwipeBackground(
          color: cs.error,
          icon: Icons.delete_outline,
          label: 'حذف پیش‌نویس',
          alignStart: false,
        ),
        child: tile,
      );
    }

    return Dismissible(
      key: ValueKey('thread_${thread.threadId}'),
      // Returning false keeps the row in place; the action triggers a bloc
      // reload which rebuilds the list authoritatively.
      confirmDismiss: (dir) async {
        if (dir == DismissDirection.startToEnd) {
          _archiveWithUndo(context, thread);
        } else {
          context.read<MessageBloc>().add(
            SetThreadRead([thread.threadId], read: thread.hasUnread),
          );
        }
        return false;
      },
      background: ThreadSwipeBackground(
        color: cs.primary,
        icon: Icons.archive_outlined,
        label: 'بایگانی',
        alignStart: true,
      ),
      secondaryBackground: ThreadSwipeBackground(
        color: cs.tertiary,
        icon: thread.hasUnread
            ? Icons.mark_chat_read_outlined
            : Icons.mark_chat_unread_outlined,
        label: thread.hasUnread ? 'خوانده‌شده' : 'نخوانده',
        alignStart: false,
      ),
      child: tile,
    );
  }

  Future<void> _openConversation(
    BuildContext context,
    MessageThread thread,
  ) async {
    final messageBloc = context.read<MessageBloc>();
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: thread.threadId,
          phoneNumber: thread.phoneNumber,
          contactName: thread.contactName,
        ),
      ),
    );
    if (mounted) {
      messageBloc.add(const LoadThreads());
      _loadDrafts();
    }
  }

  void _discardDraft(BuildContext context, MessageThread thread) {
    final draft = _drafts[thread.threadId];
    _draftStore.remove(thread.threadId);
    _loadDrafts();
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('پیش‌نویس حذف شد'),
          action: draft == null
              ? null
              : SnackBarAction(
                  label: 'واگرد',
                  onPressed: () {
                    _draftStore.save(
                      threadId: thread.threadId,
                      text: draft.text,
                      phoneNumber: draft.phoneNumber,
                      contactName: draft.contactName,
                    );
                    _loadDrafts();
                  },
                ),
        ),
      );
  }

  void _archiveWithUndo(BuildContext context, MessageThread thread) {
    final bloc = context.read<MessageBloc>();
    bloc.add(ArchiveThreads([thread.threadId], archive: true));
    ScaffoldMessenger.of(context)
      ..clearSnackBars()
      ..showSnackBar(
        SnackBar(
          content: const Text('گفتگو بایگانی شد'),
          action: SnackBarAction(
            label: 'واگرد',
            onPressed: () =>
                bloc.add(ArchiveThreads([thread.threadId], archive: false)),
          ),
        ),
      );
  }

  // ── Single-thread options sheet ──────────────────────────────────────────

  void _showThreadOptions(BuildContext context, MessageThread thread) {
    final bloc = context.read<MessageBloc>();
    final blockedBloc = context.read<BlockedNumbersBloc>();
    showThreadOptionsSheet(
      context,
      thread: thread,
      onTogglePin: () =>
          bloc.add(PinThread(thread.threadId, pin: !thread.isPinned)),
      onToggleRead: () =>
          bloc.add(SetThreadRead([thread.threadId], read: thread.hasUnread)),
      onArchive: () => _archiveWithUndo(context, thread),
      onBlock: () {
        blockedBloc.add(BlockNumber(thread.phoneNumber));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('شماره مسدود شد')));
      },
      onSelect: () => _toggleSelect(thread.threadId),
      onDelete: () => _confirmDeleteThread(context, thread),
      onDiscardDraft: thread.hasDraft
          ? () => _discardDraft(context, thread)
          : null,
    );
  }

  Future<void> _confirmDeleteThread(
    BuildContext context,
    MessageThread thread,
  ) async {
    final bloc = context.read<MessageBloc>();
    final ok = await _confirmDialog(
      context,
      'حذف این گفتگو؟ این عمل قابل بازگشت نیست.',
    );
    if (ok) bloc.add(DeleteThread(thread.threadId));
  }

  Future<void> _confirmDeleteSelected(BuildContext context) async {
    final bloc = context.read<MessageBloc>();
    final ids = _selected.toList();
    final ok = await _confirmDialog(
      context,
      'حذف ${PersianUtils.toPersianNumber('${ids.length}')} گفتگو؟ این عمل قابل بازگشت نیست.',
    );
    if (ok) {
      bloc.add(DeleteThreads(ids));
      _clearSelection();
    }
  }

  Future<bool> _confirmDialog(BuildContext context, String message) async {
    final res = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'حذف',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    return res ?? false;
  }
}
