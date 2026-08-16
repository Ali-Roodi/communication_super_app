import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/core/navigation/app_route_observer.dart';
import 'package:communication_super_app/core/services/composer_draft_store.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';
import 'spam_and_blocked_screen.dart';
import 'conversation_screen.dart';
import 'contact_selector_screen.dart';
import 'archived_threads_screen.dart';
import 'drafts_list_screen.dart';
import 'templates_list_screen.dart';
import 'scheduled_messages_screen.dart';
import 'starred_messages_screen.dart';
import 'widgets/thread_tile.dart';
import 'widgets/message_list_states.dart';
import 'widgets/messages_app_bars.dart';
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

  /// Last inbox page painted by this screen. The MessageBloc is shared with the
  /// conversation screen, so its state is regularly something the inbox can't
  /// render; this keeps the list (and its scroll offset) alive across those.
  ThreadsLoaded? _lastInbox;

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
      showUndoSnack(context, message: 'این برنامه پیام‌رسان پیش‌فرض شد');
    } else {
      // Denied — or the system auto-denied (it does after two refusals).
      // Offer the manual path: Settings → Default apps.
      showUndoSnack(
        context,
        message:
            'درخواست رد شد. می‌توانید از تنظیمات، برنامه‌های پیش‌فرض را تغییر دهید',
        undoLabel: 'تنظیمات',
        onUndo: () => _nativeSms.openDefaultAppsSettings(),
        duration: const Duration(seconds: 6),
        showCountdown: false,
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
    // Search results are a single answered query, not a page of the inbox —
    // paging into them would append unrelated threads under the results.
    if (_query.trim().isNotEmpty) return;
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
    _searchDebounce?.cancel();
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

  // ── Search ──────────────────────────────────────────────────────────────
  //
  // This used to filter the *paged-in* thread list with a raw
  // `toLowerCase().contains` over contactName / phoneNumber /
  // `thread.lastMessage`. Three things were wrong with that, and they compound:
  // it could only ever match the single newest message of a thread (usually the
  // received one — which is exactly why searching "never found my own
  // messages"), it could not see a conversation that had not been scrolled into
  // memory yet, and it bypassed `SearchText`, so «علي» did not find «علی» and
  // `0912…` did not find a thread stored as `+98912…`.
  //
  // Now the repository answers it: `searchThreads` matches the body of ANY
  // message of ANY type, plus the number, in SQLite. Contact **names** stay
  // here, because they come from the device address book and no column holds
  // them — matching them over the whole book (not the paged-in rows) is what
  // makes a thread findable by name before it has ever been paged in.

  /// Threads matching [_query], or null while the query has not been answered
  /// yet. Empty list means "answered: nothing matched".
  List<MessageThread>? _searchResults;

  /// Guards against a slow earlier query landing after a newer one.
  int _searchToken = 0;
  Timer? _searchDebounce;

  final MessageRepository _messageRepository = MessageRepository();

  /// thread id → contact name, memoized against the identity of the contact list
  /// it was built from. Rebuilding it per query would walk the whole address book
  /// on every (debounced) keystroke, and `getAllContacts` hands back the same
  /// cached list until something invalidates it.
  List<ContactModel>? _nameIndexSource;
  Map<String, String> _nameByThread = const {};

  Map<String, String> _nameIndex(List<ContactModel> contacts) {
    if (identical(_nameIndexSource, contacts)) return _nameByThread;
    _nameByThread = {
      for (final c in contacts)
        if (c.name.isNotEmpty)
          for (final p in c.phoneNumbers)
            if (PhoneNormalizer.toThreadId(p).isNotEmpty)
              PhoneNormalizer.toThreadId(p): c.name,
    };
    _nameIndexSource = contacts;
    return _nameByThread;
  }

  void _onQueryChanged(String value) {
    setState(() {
      _query = value;
      if (value.trim().isEmpty) _searchResults = null;
    });
    _searchDebounce?.cancel();
    if (value.trim().isEmpty) return;
    // Long enough that typing does not queue a scan per keystroke, short enough
    // that the list feels live.
    _searchDebounce = Timer(const Duration(milliseconds: 220), _runSearch);
  }

  Future<void> _runSearch() async {
    final query = _query.trim();
    if (query.isEmpty) return;
    final token = ++_searchToken;

    Set<String> byName = const {};
    // thread id → contact name, for the same reason `MessageBloc` keeps one: the
    // rows the repository returns carry `contacts.name`, and nothing writes to
    // that legacy table, so an un-enriched search result shows the raw number
    // for a thread the inbox above it shows by name.
    var nameByThread = const <String, String>{};
    try {
      final contacts = await ContactRepository().getAllContacts();
      byName = {
        for (final c in ContactRepository.matchContacts(contacts, query))
          for (final p in c.phoneNumbers) PhoneNormalizer.toThreadId(p),
      };
      nameByThread = _nameIndex(contacts);
    } catch (_) {
      // No contacts permission — number and body matches still answer.
    }
    final threads = await _messageRepository.searchThreads(
      query,
      alsoThreadIds: byName,
    );
    if (!mounted || token != _searchToken) return;
    setState(() {
      _searchResults = [
        for (final t in threads)
          t.contactName?.isNotEmpty == true
              ? t
              : t.copyWith(contactName: nameByThread[t.threadId]),
      ];
    });
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    if (_showDefaultSmsBanner) _recheckDefaultSilently();
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocListener<BlockedNumbersBloc, BlockedNumbersState>(
        // The inbox hides blocked conversations, so the list has to be re-read
        // whenever the blocked set changes — after a block, an unblock, an undo,
        // or an unblock done on the «هرزنامه و مسدودشده» page.
        //
        // Listening for the *result* rather than firing `LoadThreads` next to the
        // `BlockNumber` dispatch is the point: the block is written
        // asynchronously, so a reload queued alongside it read the table before
        // the row landed and painted the thread the user had just blocked.
        listenWhen: (previous, current) =>
            previous.blockedKeys.length != current.blockedKeys.length,
        listener: (context, _) {
          if (mounted) context.read<MessageBloc>().add(const LoadThreads());
        },
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
      ),
    );
  }

  /// The conversation sheet: a rounded surface that the whole list sits on
  /// (Google Messages' «صندوق» plane).
  List<Widget> _buildBodySlivers(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    // Read once for the whole list. Inside `_buildThreadRow` this was a
    // `context.watch` per row: a 200-row paged-in inbox subscribed 200 elements
    // to SettingsBloc, and any settings emit rebuilt every visible row.
    final swipeActions = context.select<SettingsBloc, bool>(
      (bloc) => bloc.state.swipeActions,
    );
    return [
      BlocConsumer<MessageBloc, MessageState>(
        listener: (context, state) {
          if (state is MessageSent || state is MessageSendFailed) {
            context.read<MessageBloc>().add(const LoadThreads());
          }
        },
        builder: (context, state) {
          Widget filler(Widget child) =>
              SliverFillRemaining(hasScrollBody: false, child: child);

          // The MessageBloc is global, so opening a conversation (or the
          // archived inbox) replaces its state with one this screen can't
          // paint. Swapping the list out for a spinner in those moments TORE
          // THE SLIVER DOWN, and with it the scroll offset — coming back from
          // a conversation always landed at the top of the inbox. Keep the
          // last inbox on screen instead; a real refresh replaces it in place.
          if (state is ThreadsLoaded && !state.archived) _lastInbox = state;
          final inbox = _lastInbox;

          if (inbox == null) {
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
            return filler(const Center(child: CircularProgressIndicator()));
          }
          if (state is MessageError && inbox.threads.isEmpty) {
            return filler(
              MessagesErrorState(
                message: state.message,
                onRetry: () => context.read<MessageBloc>().add(
                  const LoadThreads(forceRefresh: true),
                ),
              ),
            );
          }

          final searching = _query.trim().isNotEmpty;
          if (searching && _searchResults == null) {
            // The query has not been answered yet. A spinner here is honest —
            // the previous query's rows are not the answer to this one.
            return filler(const Center(child: CircularProgressIndicator()));
          }
          final threads = searching
              ? _searchResults!
              : _mergeDrafts(inbox.threads);
          if (threads.isEmpty) {
            return filler(
              searching
                  ? const MessagesNoResults()
                  : inbox.syncing
                  ? const MessagesImportingState()
                  : const MessagesEmptyState(),
            );
          }

          // Rows that exist only because of a draft (no real messages yet).
          // Search results never carry drafts, and they are not a page of the
          // inbox — so no "load more" spinner either.
          final realIds = {for (final t in inbox.threads) t.threadId};
          final hasMore = !searching && inbox.hasMore;
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
                itemCount: threads.length + (hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (hasMore && index == threads.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  final thread = threads[index];
                  final draftOnly =
                      thread.hasDraft && !realIds.contains(thread.threadId);
                  return _buildThreadRow(
                    context,
                    thread,
                    draftOnly: draftOnly,
                    swipeActions: swipeActions,
                  );
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
        onBack: () {
          _searchDebounce?.cancel();
          _searchController.clear();
          setState(() {
            _searching = false;
            _query = '';
            _searchResults = null;
          });
        },
        onClear: () {
          _searchDebounce?.cancel();
          _searchController.clear();
          setState(() {
            _query = '';
            _searchResults = null;
          });
        },
        onChanged: _onQueryChanged,
      );
    }
    return MessagesDefaultAppBar(
      onSearch: () => setState(() => _searching = true),
      onOpenArchived: _openArchived,
      onOpenDrafts: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const DraftsListScreen()),
      ),
      onOpenTemplates: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const TemplatesListScreen()),
      ),
      onOpenScheduled: () => Navigator.push(
        context,
        MaterialPageRoute(builder: (_) => const ScheduledMessagesScreen()),
      ),
      onOpenSpamAndBlocked: () async {
        final bloc = context.read<MessageBloc>();
        await Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const SpamAndBlockedScreen()),
        );
        // Unblocking there puts a conversation back into this list.
        bloc.add(const LoadThreads());
      },
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
    final all = _lastInbox?.threads ?? const <MessageThread>[];
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

  /// Selects every row currently on screen — the search results while
  /// searching, the paged-in inbox otherwise.
  void _selectAllVisible() {
    final visible =
        _searchResults ?? _lastInbox?.threads ?? const <MessageThread>[];
    setState(() {
      _selected
        ..clear()
        ..addAll(visible.map((t) => t.threadId));
    });
  }

  /// Blocks the selected threads, asking once (Google Messages folds the spam
  /// report into that same question — see [showBlockNumberDialog]).
  ///
  /// Blocking moves the conversations out of this list into «هرزنامه و
  /// مسدودشده», so the inbox is reloaded afterwards: without that the rows the
  /// user just blocked stay on screen and the block reads as a no-op.
  Future<void> _blockSelected() async {
    final all = _lastInbox?.threads ?? const <MessageThread>[];
    final chosen = all
        .where((t) => _selected.contains(t.threadId))
        .toList(growable: false);
    if (chosen.isEmpty) {
      _clearSelection();
      return;
    }

    final decision = await showBlockNumberDialog(
      context,
      phoneNumber: chosen.first.phoneNumber,
      contactName: chosen.length == 1 ? chosen.first.contactName : null,
      numberCount: chosen.length,
    );
    if (decision == null || !mounted) return;

    final blockedBloc = context.read<BlockedNumbersBloc>();
    for (final t in chosen) {
      blockedBloc.add(BlockNumber(t.phoneNumber, report: decision.report));
    }
    _clearSelection();
    // No LoadThreads here: the BlocListener above reloads once the block has
    // actually been written (see its comment).

    final label = chosen.length == 1
        ? (chosen.first.contactName?.isNotEmpty == true
              ? chosen.first.contactName!
              : PersianUtils.displayPhone(chosen.first.phoneNumber))
        : '${PersianUtils.toPersianNumber('${chosen.length}')} گفتگو';
    showUndoSnack(
      context,
      message: decision.report
          ? '«$label» مسدود و به‌عنوان هرزنامه گزارش شد'
          : '«$label» مسدود شد',
      onUndo: () {
        for (final t in chosen) {
          blockedBloc.add(
            UnblockNumber(BlockedNumberModel.normalize(t.phoneNumber)),
          );
        }
      },
    );
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
    required bool swipeActions,
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
      // Long-press *enters multi-select* — Google Messages has no per-thread
      // sheet; pin / mark read / archive / block / delete all live in the
      // selection bar, so one gesture reaches every action.
      onLongPress: () {
        if (draftOnly && !_selectionMode) {
          // A draft-only row is synthetic (no conversation behind it), so it
          // can't take part in the thread actions — its long-press discards.
          _discardDraft(context, thread);
          return;
        }
        HapticFeedback.mediumImpact();
        _toggleSelect(thread.threadId);
      },
    );

    // «کشیدن برای بایگانی» (Settings → پیامک‌ها) turns the swipe gestures off.
    if (!swipeActions) return tile;

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
    showUndoSnack(
      context,
      message: 'پیش‌نویس حذف شد',
      onUndo: draft == null
          ? null
          : () {
              _draftStore.save(
                threadId: thread.threadId,
                text: draft.text,
                phoneNumber: draft.phoneNumber,
                contactName: draft.contactName,
              );
              _loadDrafts();
            },
    );
  }

  void _archiveWithUndo(BuildContext context, MessageThread thread) {
    final bloc = context.read<MessageBloc>();
    bloc.add(ArchiveThreads([thread.threadId], archive: true));
    showUndoSnack(
      context,
      message: 'گفتگو بایگانی شد',
      onUndo: () => bloc.add(ArchiveThreads([thread.threadId], archive: false)),
    );
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
