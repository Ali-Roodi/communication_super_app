import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'drafts_list_screen.dart';
import 'template_picker_screen.dart';
import 'widgets/message_bubble.dart';
import 'widgets/conversation_app_bars.dart';
import 'widgets/conversation_sheets.dart';
import 'widgets/message_composer.dart';

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
    return ConversationAppBar(
      title: _title,
      phoneNumber: widget.phoneNumber,
      hasName: _hasName,
      onOpenContact: _openContact,
      onCall: () => NativeCallService.instance.makeCall(widget.phoneNumber),
      onMenuSelected: _onMenu,
    );
  }

  PreferredSizeWidget _selectionAppBar() {
    return ConversationSelectionAppBar(
      selectedCount: _selected.length,
      onClear: () => setState(_selected.clear),
      onCopy: _copySelected,
      onDelete: () => _confirmDeleteMessages(_selected.toList()),
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
    showMessageOptionsSheet(
      context,
      onCopy: () => _copyMessage(msg),
      onForward: () => ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('به‌زودی'))),
      onInfo: () => _showMessageInfo(msg),
      onSelect: () => _toggleSelect(msg.id),
      onDelete: () => _confirmDeleteMessages([msg.id]),
    );
  }

  void _copyMessage(MessageModel msg) {
    Clipboard.setData(ClipboardData(text: msg.body));
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('کپی شد')));
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
    return MessageComposer(
      controller: _messageController,
      showStickers: _showStickers,
      onToggleStickers: () {
        if (!_showStickers) FocusScope.of(context).unfocus();
        setState(() => _showStickers = !_showStickers);
      },
      onAttach: _showAttachmentSheet,
      onSend: _sendMessage,
      onStickerSelected: _sendSticker,
    );
  }

  void _sendSticker(String sticker) {
    _messageBloc.add(
      SendMessage(phoneNumber: widget.phoneNumber, body: sticker),
    );
  }

  void _showAttachmentSheet() {
    showAttachmentSheet(
      context,
      onInsertDraft: _insertDraft,
      onInsertTemplate: _insertTemplate,
      onComingSoon: () => ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('به‌زودی'))),
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
