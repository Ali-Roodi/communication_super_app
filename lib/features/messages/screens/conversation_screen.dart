import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'drafts_list_screen.dart';
import 'template_picker_screen.dart';
import 'widgets/message_bubble.dart';

/// Google Messages style chat screen.
///
/// Bubbles are grouped (same sender within 2 min), separated by day chips, and
/// timestamps appear only on the last bubble of a group or after a 10-minute
/// gap. Supports long-press message actions and message multi-select delete.
class ConversationScreen extends StatefulWidget {
  final String threadId;
  final String phoneNumber;
  final String? contactName;

  const ConversationScreen({
    super.key,
    required this.threadId,
    required this.phoneNumber,
    this.contactName,
  });

  /// Opens a conversation for any phone number — saved or not. The thread ID is
  /// derived from the number, so unsaved numbers resolve correctly and the
  /// title falls back to the number when [contactName] is null.
  ConversationScreen.forPhone(
    this.phoneNumber, {
    super.key,
    String? contactName,
  }) : threadId = PhoneNormalizer.toThreadId(phoneNumber),
       contactName = (contactName?.isNotEmpty ?? false) ? contactName : null;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen> {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  bool _isLoadingMore = false;
  bool _showScrollToBottom = false;
  bool _showStickers = false;

  /// Selected message ids (message multi-select mode).
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  late final MessageBloc _messageBloc;

  bool get _hasName => widget.contactName != null;
  String get _title =>
      widget.contactName ?? PhoneNormalizer.toNational(widget.phoneNumber);

  @override
  void initState() {
    super.initState();
    _messageBloc = context.read<MessageBloc>();
    _messageBloc.add(LoadMessages(widget.threadId));
    _scrollController.addListener(_onScroll);
    _messageController.addListener(() => setState(() {}));
  }

  void _onScroll() {
    if (!mounted) return;
    final pos = _scrollController.position;
    // Show the scroll-to-bottom FAB once the user scrolls up a bit.
    final shouldShow = pos.maxScrollExtent - pos.pixels > 400;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
    if (_isLoadingMore) return;
    final state = context.read<MessageBloc>().state;
    if (state is! MessagesLoaded || !state.hasMore) return;
    if (pos.pixels <= 200) {
      _isLoadingMore = true;
      context.read<MessageBloc>().add(LoadMoreMessages(widget.threadId));
    }
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _messageController.dispose();
    _scrollController.dispose();
    _messageBloc.add(const LoadThreads());
    super.dispose();
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    _messageController.clear();
    _messageBloc.add(SendMessage(phoneNumber: widget.phoneNumber, body: text));
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      _scrollController.animateTo(
        _scrollController.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  // ── Build ────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: _selectionMode ? _selectionAppBar() : _normalAppBar(),
        body: BlocListener<MessageBloc, MessageState>(
          listenWhen: (_, curr) =>
              curr is MessagesLoaded ||
              curr is MessageSent ||
              curr is MessageSendFailed ||
              curr is MessageError,
          listener: (context, state) {
            if (state is MessagesLoaded) {
              _isLoadingMore = false;
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (_scrollController.hasClients && !_showScrollToBottom) {
                  _scrollController.jumpTo(
                    _scrollController.position.maxScrollExtent,
                  );
                }
              });
            } else if (state is MessageSent) {
              context.read<MessageBloc>().add(LoadMessages(widget.threadId));
            } else if (state is MessageSendFailed) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.userMessage),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            } else if (state is MessageError) {
              ScaffoldMessenger.of(context).showSnackBar(
                SnackBar(
                  content: Text(state.message),
                  backgroundColor: Theme.of(context).colorScheme.error,
                  behavior: SnackBarBehavior.floating,
                ),
              );
            }
          },
          child: Column(
            children: [
              Expanded(child: _buildMessageList()),
              _buildComposer(),
            ],
          ),
        ),
        floatingActionButton: _showScrollToBottom && !_selectionMode
            ? FloatingActionButton.small(
                heroTag: 'scroll_bottom',
                onPressed: _scrollToBottom,
                child: const Icon(Icons.keyboard_arrow_down),
              )
            : null,
      ),
    );
  }

  // ── App bars ──────────────────────────────────────────────────────────────

  PreferredSizeWidget _normalAppBar() {
    final theme = Theme.of(context);
    return AppBar(
      titleSpacing: 0,
      title: InkWell(
        onTap: _openContact,
        child: Row(
          children: [
            AvatarWidget(name: _title, size: 36),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 17),
                  ),
                  if (_hasName)
                    Text(
                      PhoneNormalizer.toNational(widget.phoneNumber),
                      style: theme.textTheme.bodySmall,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
      actions: [
        IconButton(
          icon: const Icon(Icons.call_outlined),
          tooltip: 'تماس',
          onPressed: () =>
              NativeCallService.instance.makeCall(widget.phoneNumber),
        ),
        PopupMenuButton<String>(
          onSelected: _onMenu,
          itemBuilder: (_) => [
            if (_hasName)
              const PopupMenuItem(value: 'view', child: Text('مشاهده مخاطب'))
            else
              const PopupMenuItem(
                value: 'add',
                child: Text('افزودن به مخاطبین'),
              ),
            const PopupMenuItem(
              value: 'block',
              child: Text('مسدود کردن و گزارش هرزنامه'),
            ),
            const PopupMenuItem(value: 'delete', child: Text('حذف گفتگو')),
          ],
        ),
      ],
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return AppBar(
      leading: IconButton(
        icon: const Icon(Icons.close),
        onPressed: () => setState(_selected.clear),
      ),
      title: Text('${_selected.length}'),
      actions: [
        IconButton(
          icon: const Icon(Icons.copy_outlined),
          tooltip: 'کپی',
          onPressed: _copySelected,
        ),
        IconButton(
          icon: const Icon(Icons.delete_outline),
          tooltip: 'حذف',
          onPressed: () => _confirmDeleteMessages(_selected.toList()),
        ),
      ],
    );
  }

  void _onMenu(String value) {
    switch (value) {
      case 'view':
        _openContact();
      case 'add':
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) =>
                AddEditContactScreen(initialPhone: widget.phoneNumber),
          ),
        );
      case 'block':
        context.read<BlockedNumbersBloc>().add(BlockNumber(widget.phoneNumber));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('شماره مسدود شد')));
      case 'delete':
        _confirmDeleteConversation();
    }
  }

  void _openContact() {
    if (!_hasName) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              AddEditContactScreen(initialPhone: widget.phoneNumber),
        ),
      );
    } else {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('به‌زودی')));
    }
  }

  // ── Message list with grouping + date separators ──────────────────────────

  Widget _buildMessageList() {
    return BlocBuilder<MessageBloc, MessageState>(
      buildWhen: (_, curr) => curr is MessageLoading || curr is MessagesLoaded,
      builder: (context, state) {
        if (state is MessageLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state is MessagesLoaded) {
          if (state.messages.isEmpty) {
            return const Center(child: Text('هنوز پیامی نیست'));
          }
          final msgs = state.messages;
          return ListView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
            itemCount: msgs.length,
            itemBuilder: (context, i) {
              final msg = msgs[i];
              final prev = i > 0 ? msgs[i - 1] : null;
              final next = i < msgs.length - 1 ? msgs[i + 1] : null;
              return _buildMessageItem(msg, prev, next);
            },
          );
        }
        return const SizedBox.shrink();
      },
    );
  }

  bool _sameGroup(MessageModel a, MessageModel b) {
    if (a.type != b.type) return false;
    final gap = (a.timestamp.difference(b.timestamp)).abs();
    return gap <= const Duration(minutes: 2) &&
        _sameDay(a.timestamp, b.timestamp);
  }

  bool _sameDay(DateTime a, DateTime b) =>
      a.year == b.year && a.month == b.month && a.day == b.day;

  Widget _buildMessageItem(
    MessageModel msg,
    MessageModel? prev,
    MessageModel? next,
  ) {
    final showDateSep =
        prev == null || !_sameDay(prev.timestamp, msg.timestamp);
    final isLastInGroup = next == null || !_sameGroup(msg, next);
    final gapToNext = next?.timestamp.difference(msg.timestamp);
    final showTimestamp =
        isLastInGroup ||
        (gapToNext != null && gapToNext > const Duration(minutes: 10));
    final selected = _selected.contains(msg.id);

    return Column(
      children: [
        if (showDateSep) _dateSeparator(msg.timestamp),
        MessageBubble(
          message: msg,
          isLastInGroup: isLastInGroup,
          showTimestamp: showTimestamp,
          selected: selected,
          selectionMode: _selectionMode,
          onTap: () {
            if (_selectionMode) _toggleSelect(msg.id);
          },
          onLongPress: () {
            if (_selectionMode) {
              _toggleSelect(msg.id);
            } else {
              _showMessageOptions(msg);
            }
          },
          onRetry: msg.status == MessageStatus.failed
              ? () => _messageBloc.add(
                  SendMessage(phoneNumber: widget.phoneNumber, body: msg.body),
                )
              : null,
        ),
      ],
    );
  }

  Widget _dateSeparator(DateTime dt) {
    final now = DateTime.now();
    final today = DateTime(now.year, now.month, now.day);
    final that = DateTime(dt.year, dt.month, dt.day);
    final diff = today.difference(that).inDays;
    String label;
    if (diff == 0) {
      label = 'امروز';
    } else if (diff == 1) {
      label = 'دیروز';
    } else {
      label = DateFormatter.formatDatePersian(
        dt,
      ).replaceAll(RegExp(r' \d{2}:\d{2}$'), '');
    }
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: theme.colorScheme.surfaceContainerHighest,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Text(
            PersianUtils.toPersianNumber(label),
            style: theme.textTheme.bodySmall,
          ),
        ),
      ),
    );
  }

  void _toggleSelect(String id) {
    setState(() {
      if (!_selected.remove(id)) _selected.add(id);
    });
  }

  // ── Message long-press options ─────────────────────────────────────────────

  void _showMessageOptions(MessageModel msg) {
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
                leading: const Icon(Icons.copy_outlined),
                title: const Text('کپی'),
                onTap: () {
                  Clipboard.setData(ClipboardData(text: msg.body));
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('کپی شد')));
                },
              ),
              ListTile(
                leading: const Icon(Icons.forward_outlined),
                title: const Text('هدایت'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  ScaffoldMessenger.of(
                    context,
                  ).showSnackBar(const SnackBar(content: Text('به‌زودی')));
                },
              ),
              ListTile(
                leading: const Icon(Icons.info_outline),
                title: const Text('اطلاعات'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _showMessageInfo(msg);
                },
              ),
              ListTile(
                leading: const Icon(Icons.checklist),
                title: const Text('انتخاب'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _toggleSelect(msg.id);
                },
              ),
              ListTile(
                leading: const Icon(
                  Icons.delete_outline,
                  color: AppColors.danger,
                ),
                title: const Text(
                  'حذف',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _confirmDeleteMessages([msg.id]);
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _showMessageInfo(MessageModel msg) {
    final statusLabel = switch (msg.status) {
      MessageStatus.pending => 'در حال ارسال',
      MessageStatus.sent => 'ارسال‌شده',
      MessageStatus.delivered => 'تحویل‌شده',
      MessageStatus.failed => 'ناموفق',
    };
    showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اطلاعات پیام'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text('زمان: ${DateFormatter.formatDateTime(msg.timestamp)}'),
              const SizedBox(height: 8),
              if (msg.type == MessageType.sent) Text('وضعیت: $statusLabel'),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('باشه'),
            ),
          ],
        ),
      ),
    );
  }

  void _copySelected() {
    final state = context.read<MessageBloc>().state;
    if (state is! MessagesLoaded) return;
    final texts = state.messages
        .where((m) => _selected.contains(m.id))
        .map((m) => m.body)
        .join('\n');
    Clipboard.setData(ClipboardData(text: texts));
    setState(_selected.clear);
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('کپی شد')));
  }

  Future<void> _confirmDeleteMessages(List<String> ids) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text(
            ids.length == 1 ? 'این پیام حذف شود؟' : 'حذف ${ids.length} پیام؟',
          ),
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
    if (ok == true) {
      _messageBloc.add(DeleteMessages(widget.threadId, ids));
      setState(_selected.clear);
    }
  }

  Future<void> _confirmDeleteConversation() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: const Text('حذف این گفتگو؟ این عمل قابل بازگشت نیست.'),
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
    if (ok == true && mounted) {
      _messageBloc.add(DeleteThread(widget.threadId));
      Navigator.of(context).pop();
    }
  }

  // ── Composer ────────────────────────────────────────────────────────────────

  Widget _buildComposer() {
    final theme = Theme.of(context);
    final text = _messageController.text;
    final hasText = text.trim().isNotEmpty;
    final len = text.length;
    final segments = len == 0 ? 0 : (len / 160).ceil();

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (len > 140)
              Padding(
                padding: const EdgeInsets.only(bottom: 4, right: 16, left: 16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    if (len > 160)
                      Container(
                        margin: const EdgeInsets.only(left: 8),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 1,
                        ),
                        decoration: BoxDecoration(
                          color: theme.colorScheme.tertiary,
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: const Text(
                          'MMS',
                          style: TextStyle(color: Colors.white, fontSize: 11),
                        ),
                      ),
                    Text(
                      '$len / $segments SMS',
                      style: theme.textTheme.bodySmall,
                    ),
                  ],
                ),
              ),
            Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                IconButton(
                  icon: const Icon(Icons.add_circle_outline),
                  tooltip: 'پیوست',
                  onPressed: _showAttachmentSheet,
                ),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: theme.brightness == Brightness.dark
                          ? theme.colorScheme.surfaceContainerHighest
                          : Colors.grey[200],
                      borderRadius: BorderRadius.circular(24),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: [
                        Expanded(
                          child: TextField(
                            controller: _messageController,
                            minLines: 1,
                            maxLines: 4,
                            textInputAction: TextInputAction.newline,
                            decoration: const InputDecoration(
                              hintText: 'پیام',
                              border: InputBorder.none,
                              contentPadding: EdgeInsets.symmetric(
                                vertical: 10,
                              ),
                            ),
                          ),
                        ),
                        IconButton(
                          icon: Icon(
                            _showStickers
                                ? Icons.keyboard
                                : Icons.emoji_emotions_outlined,
                          ),
                          tooltip: 'استیکر',
                          onPressed: () {
                            if (!_showStickers) {
                              FocusScope.of(context).unfocus();
                            }
                            setState(() => _showStickers = !_showStickers);
                          },
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 4),
                MessageSendButton(enabled: hasText, onSend: _sendMessage),
              ],
            ),
            if (_showStickers) _buildStickerPanel(theme),
          ],
        ),
      ),
    );
  }

  /// Emoji "sticker" picker. Tapping a sticker sends it immediately as a
  /// message (no image assets needed).
  static const List<String> _stickers = [
    '😀',
    '😂',
    '😍',
    '😎',
    '😭',
    '😡',
    '👍',
    '👎',
    '🙏',
    '👏',
    '🎉',
    '❤️',
    '🔥',
    '💯',
    '😴',
    '🤔',
    '😅',
    '😉',
    '😘',
    '🥳',
    '😱',
    '🤩',
    '💀',
    '✨',
    '🌹',
    '☕',
    '🍕',
    '⚽',
    '🎂',
    '🚗',
    '📱',
    '✅',
  ];

  Widget _buildStickerPanel(ThemeData theme) {
    return Container(
      height: 220,
      margin: const EdgeInsets.only(top: 4),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
        borderRadius: BorderRadius.circular(16),
      ),
      child: GridView.count(
        crossAxisCount: 6,
        padding: const EdgeInsets.all(8),
        children: [
          for (final s in _stickers)
            InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => _sendSticker(s),
              child: Center(
                child: Text(s, style: const TextStyle(fontSize: 30)),
              ),
            ),
        ],
      ),
    );
  }

  void _sendSticker(String sticker) {
    _messageBloc.add(
      SendMessage(phoneNumber: widget.phoneNumber, body: sticker),
    );
  }

  void _showAttachmentSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Wrap(
            children: [
              // Functional: insert a saved draft or a generated template.
              ListTile(
                leading: const Icon(Icons.edit_note_outlined),
                title: const Text('پیش‌نویس'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _insertDraft();
                },
              ),
              ListTile(
                leading: const Icon(Icons.description_outlined),
                title: const Text('قالب آماده'),
                onTap: () {
                  Navigator.pop(sheetCtx);
                  _insertTemplate();
                },
              ),
              const Divider(height: 1),
              for (final item in const [
                (Icons.photo_camera_outlined, 'دوربین'),
                (Icons.photo_library_outlined, 'گالری'),
                (Icons.mic_none_outlined, 'صدا'),
                (Icons.location_on_outlined, 'موقعیت'),
              ])
                ListTile(
                  leading: Icon(item.$1),
                  title: Text(item.$2),
                  onTap: () {
                    Navigator.pop(sheetCtx);
                    ScaffoldMessenger.of(
                      context,
                    ).showSnackBar(const SnackBar(content: Text('به‌زودی')));
                  },
                ),
            ],
          ),
        ),
      ),
    );
  }

  /// Opens the drafts picker and inserts the chosen draft's body into the
  /// composer (appending to any existing text).
  Future<void> _insertDraft() async {
    final body = await Navigator.of(context).push<String>(
      MaterialPageRoute(builder: (_) => const DraftsListScreen(pickMode: true)),
    );
    if (body != null && body.isNotEmpty) _appendToComposer(body);
  }

  Future<void> _insertTemplate() async {
    final text = await showTemplatePicker(
      context,
      contactName: widget.contactName,
    );
    if (text != null && text.isNotEmpty) _appendToComposer(text);
  }

  void _appendToComposer(String text) {
    final existing = _messageController.text;
    _messageController.text = existing.isEmpty ? text : '$existing\n$text';
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: _messageController.text.length),
    );
  }
}
