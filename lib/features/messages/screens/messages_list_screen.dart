import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
import 'conversation_screen.dart';
import 'contact_selector_screen.dart';
import 'archived_threads_screen.dart';
import 'widgets/thread_tile.dart';

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
    with WidgetsBindingObserver {
  bool _hasLoadedInitially = false;
  final ScrollController _scrollController = ScrollController();
  final TextEditingController _searchController = TextEditingController();

  bool _searching = false;
  String _query = '';
  final Set<String> _selected = {};

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
    }
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
    final theme = Theme.of(context);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: _buildAppBar(context),
        body: BlocConsumer<MessageBloc, MessageState>(
          listener: (context, state) {
            if (state is MessageSent || state is MessageSendFailed) {
              context.read<MessageBloc>().add(const LoadThreads());
            }
          },
          builder: (context, state) {
            if (state is MessageLoading ||
                state is MessageInitial ||
                state is MessagesLoaded ||
                state is MessageSent ||
                state is MessageSendFailed) {
              return const Center(child: CircularProgressIndicator());
            }
            if (state is MessageError) {
              return _buildErrorState(context, state.message, theme);
            }
            if (state is ThreadsLoaded) {
              // The archived view is shown on its own screen; ignore that state
              // here (it only briefly appears while that screen is pushed).
              if (state.archived) {
                return const Center(child: CircularProgressIndicator());
              }
              final threads = _visibleThreads(state.threads);
              if (threads.isEmpty) {
                return _query.isEmpty
                    ? _buildEmptyState(theme)
                    : _buildNoResults(theme);
              }
              return ListView.builder(
                controller: _scrollController,
                padding: const EdgeInsets.only(bottom: 88),
                itemCount: threads.length + (state.hasMore ? 1 : 0),
                itemBuilder: (context, index) {
                  if (state.hasMore && index == threads.length) {
                    return const Padding(
                      padding: EdgeInsets.all(16),
                      child: Center(child: CircularProgressIndicator()),
                    );
                  }
                  return _buildThreadRow(context, threads[index]);
                },
              );
            }
            return const Center(child: CircularProgressIndicator());
          },
        ),
        floatingActionButton: _selectionMode || _searching
            ? null
            : FloatingActionButton.extended(
                heroTag: 'messages_fab',
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ContactSelectorScreen()),
                ),
                icon: const Icon(Icons.edit_outlined),
                label: const Text('پیام جدید'),
              ),
      ),
    );
  }

  // ── App bars ───────────────────────────────────────────────────────────

  PreferredSizeWidget _buildAppBar(BuildContext context) {
    if (_selectionMode) return _selectionAppBar(context);
    if (_searching) return _searchAppBar(context);
    return AppBar(
      title: const Text('پیام‌ها'),
      actions: [
        IconButton(
          icon: const Icon(Icons.search),
          tooltip: 'جستجو',
          onPressed: () => setState(() => _searching = true),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            switch (v) {
              case 'archived':
                final bloc = context.read<MessageBloc>();
                Navigator.push(
                  context,
                  MaterialPageRoute(
                      builder: (_) => const ArchivedThreadsScreen()),
                ).then((_) {
                  if (mounted) bloc.add(const LoadThreads());
                });
              case 'settings':
                Navigator.push(
                  context,
                  MaterialPageRoute(builder: (_) => const SettingsScreen()),
                );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'archived', child: Text('بایگانی')),
            PopupMenuItem(value: 'settings', child: Text('تنظیمات')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _searchAppBar(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.arrow_forward),
        onPressed: () {
          setState(() {
            _searching = false;
            _query = '';
            _searchController.clear();
          });
        },
      ),
      title: TextField(
        controller: _searchController,
        autofocus: true,
        textInputAction: TextInputAction.search,
        decoration: const InputDecoration(
          hintText: 'جستجو در پیام‌ها',
          border: InputBorder.none,
        ),
        onChanged: (v) => setState(() => _query = v),
      ),
      actions: [
        if (_query.isNotEmpty)
          IconButton(
            icon: const Icon(Icons.close),
            onPressed: () => setState(() {
              _query = '';
              _searchController.clear();
            }),
          ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar(BuildContext context) {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: _clearSelection,
      ),
      title: Text('${_selected.length}'),
      actions: [
        IconButton(
          icon: const Icon(Icons.mark_chat_read_outlined),
          tooltip: 'علامت‌گذاری خوانده‌شده',
          onPressed: () {
            context
                .read<MessageBloc>()
                .add(SetThreadRead(_selected.toList(), read: true));
            _clearSelection();
          },
        ),
        IconButton(
          icon: const Icon(Icons.archive_outlined),
          tooltip: 'بایگانی',
          onPressed: () {
            context
                .read<MessageBloc>()
                .add(ArchiveThreads(_selected.toList(), archive: true));
            _clearSelection();
          },
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'حذف',
          onPressed: () => _confirmDeleteSelected(context),
        ),
        PopupMenuButton<String>(
          onSelected: (v) {
            final state = context.read<MessageBloc>().state;
            final all = state is ThreadsLoaded ? state.threads : const <MessageThread>[];
            switch (v) {
              case 'select_all':
                setState(() {
                  _selected
                    ..clear()
                    ..addAll(_visibleThreads(all).map((t) => t.threadId));
                });
              case 'mark_unread':
                context
                    .read<MessageBloc>()
                    .add(SetThreadRead(_selected.toList(), read: false));
                _clearSelection();
              case 'block':
                final blockedBloc = context.read<BlockedNumbersBloc>();
                for (final t in all.where((t) => _selected.contains(t.threadId))) {
                  blockedBloc.add(BlockNumber(t.phoneNumber));
                }
                _clearSelection();
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('شماره‌ها مسدود شدند')),
                );
            }
          },
          itemBuilder: (_) => const [
            PopupMenuItem(value: 'select_all', child: Text('انتخاب همه')),
            PopupMenuItem(value: 'mark_unread', child: Text('علامت‌گذاری نخوانده')),
            PopupMenuItem(value: 'block', child: Text('مسدود کردن')),
          ],
        ),
      ],
    );
  }

  // ── Thread row (swipe + tile) ────────────────────────────────────────────

  Widget _buildThreadRow(BuildContext context, MessageThread thread) {
    final selected = _selected.contains(thread.threadId);
    final cs = Theme.of(context).colorScheme;

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
      background: _swipeBg(
        color: cs.primary,
        icon: Icons.archive_outlined,
        label: 'بایگانی',
        alignStart: true,
      ),
      secondaryBackground: _swipeBg(
        color: cs.tertiary,
        icon: thread.hasUnread
            ? Icons.mark_chat_read_outlined
            : Icons.mark_chat_unread_outlined,
        label: thread.hasUnread ? 'خوانده‌شده' : 'نخوانده',
        alignStart: false,
      ),
      child: ThreadTile(
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
          } else {
            _showThreadOptions(context, thread);
          }
        },
      ),
    );
  }

  Widget _swipeBg({
    required Color color,
    required IconData icon,
    required String label,
    required bool alignStart,
  }) {
    return Container(
      color: color.withValues(alpha: 0.85),
      alignment: alignStart
          ? AlignmentDirectional.centerStart
          : AlignmentDirectional.centerEnd,
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, color: Colors.white),
          const SizedBox(width: 8),
          Text(label, style: const TextStyle(color: Colors.white)),
        ],
      ),
    );
  }

  Future<void> _openConversation(
      BuildContext context, MessageThread thread) async {
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
    if (mounted) messageBloc.add(const LoadThreads());
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
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: Icon(
                    thread.isPinned ? Icons.push_pin : Icons.push_pin_outlined),
                title: Text(thread.isPinned ? 'برداشتن سنجاق' : 'سنجاق کردن'),
                onTap: () {
                  bloc.add(PinThread(thread.threadId, pin: !thread.isPinned));
                  Navigator.pop(sheetCtx);
                },
              ),
              ListTile(
                leading: Icon(thread.hasUnread
                    ? Icons.mark_chat_read_outlined
                    : Icons.mark_chat_unread_outlined),
                title: Text(thread.hasUnread
                    ? 'علامت‌گذاری خوانده‌شده'
                    : 'علامت‌گذاری نخوانده'),
                onTap: () {
                  bloc.add(SetThreadRead([thread.threadId],
                      read: thread.hasUnread));
                  Navigator.pop(sheetCtx);
                },
              ),
              ListTile(
                leading: const Icon(Icons.archive_outlined),
                title: const Text('بایگانی'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _archiveWithUndo(context, thread);
                },
              ),
              ListTile(
                leading: const Icon(Icons.block),
                title: const Text('مسدود کردن و گزارش هرزنامه'),
                onTap: () {
                  blockedBloc.add(BlockNumber(thread.phoneNumber));
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('شماره مسدود شد')),
                  );
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('انتخاب'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _toggleSelect(thread.threadId);
                },
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline, color: Colors.red),
                title: const Text('حذف گفتگو',
                    style: TextStyle(color: Colors.red)),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDeleteThread(context, thread);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _confirmDeleteThread(
      BuildContext context, MessageThread thread) async {
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
      'حذف ${ids.length} گفتگو؟ این عمل قابل بازگشت نیست.',
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
              child: const Text('حذف', style: TextStyle(color: Colors.red)),
            ),
          ],
        ),
      ),
    );
    return res ?? false;
  }

  // ── Empty / error / no-results states ──────────────────────────────────────

  Widget _buildNoResults(ThemeData theme) => Center(
        child: Text('نتیجه‌ای یافت نشد',
            style: TextStyle(color: theme.textTheme.bodyMedium?.color)),
      );

  Widget _buildErrorState(
      BuildContext context, String errorMessage, ThemeData theme) {
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.error_outline, size: 64, color: theme.colorScheme.error),
            const SizedBox(height: 16),
            Text(
              'خطا در بارگذاری پیام‌ها',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w600,
                color: theme.textTheme.bodyLarge?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 12),
            Text(errorMessage,
                style: TextStyle(
                    fontSize: 14, color: theme.textTheme.bodyMedium?.color),
                textAlign: TextAlign.center),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => context
                  .read<MessageBloc>()
                  .add(const LoadThreads(forceRefresh: true)),
              icon: const Icon(Icons.refresh),
              label: const Text('تلاش مجدد'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(ThemeData theme) {
    return Container(
      color: theme.scaffoldBackgroundColor,
      padding: const EdgeInsets.all(24),
      child: Center(
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Icon(Icons.chat_bubble_outline,
                size: 64,
                color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.5)),
            const SizedBox(height: 16),
            Text(
              'هیچ پیامکی موجود نیست',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w500,
                color: theme.textTheme.bodyLarge?.color,
              ),
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 8),
            Text('پیام‌های شما در اینجا نمایش داده خواهند شد',
                style: TextStyle(
                    fontSize: 14, color: theme.textTheme.bodyMedium?.color),
                textAlign: TextAlign.center),
          ],
        ),
      ),
    );
  }
}
