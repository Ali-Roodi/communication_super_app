import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/composer_draft_store.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../bloc/scheduled_state.dart';
import '../models/scheduled_message_model.dart';
import 'drafts_list_screen.dart';
import 'template_picker_screen.dart';
import 'schedule_message_screen.dart';
import 'widgets/message_bubble.dart';
import 'contact_selector_screen.dart';
import 'widgets/conversation_app_bars.dart';
import 'widgets/conversation_sheets.dart';
import 'widgets/message_composer.dart';
import 'widgets/scheduled_bubble.dart';

/// Google Messages style chat screen.
///
/// Bubbles are grouped (same sender within 2 min), separated by day chips, and
/// timestamps appear only on the last bubble of a group or after a 10-minute
/// gap. Supports long-press message actions and message multi-select delete.
class ConversationScreen extends StatefulWidget {
  final String threadId;
  final String phoneNumber;
  final String? contactName;

  /// Text to seed the composer with — used by «هدایت» (forward), which opens
  /// the target chat with the forwarded body already typed. A saved draft for
  /// the thread wins over this, so forwarding never eats unsent text.
  final String? initialText;

  const ConversationScreen({
    super.key,
    required this.threadId,
    required this.phoneNumber,
    this.contactName,
    this.initialText,
  });

  /// Opens a conversation for any phone number — saved or not. The thread ID is
  /// derived from the number, so unsaved numbers resolve correctly and the
  /// title falls back to the number when [contactName] is null.
  ConversationScreen.forPhone(
    this.phoneNumber, {
    super.key,
    String? contactName,
    this.initialText,
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

  // Per-thread unsent composer text, so leaving the chat doesn't lose it and
  // the inbox can surface it as a draft.
  final ComposerDraftStore _draftStore = ComposerDraftStore();

  /// Selected message ids (message multi-select mode).
  final Set<String> _selected = {};
  bool get _selectionMode => _selected.isNotEmpty;

  late final MessageBloc _messageBloc;

  bool get _hasName => widget.contactName != null;
  String get _title =>
      widget.contactName ??
      PersianUtils.displayPhone(PhoneNormalizer.toNational(widget.phoneNumber));

  @override
  void initState() {
    super.initState();
    _messageBloc = context.read<MessageBloc>();
    _messageBloc.add(LoadMessages(widget.threadId));
    // Re-read the schedules table on entry: a message delivered while this
    // screen was gone (native worker, cold start) would otherwise still show as
    // a pending ghost bubble from the BLoC's cached state.
    context.read<ScheduledMessageBloc>().add(const LoadScheduled());
    _scrollController.addListener(_onScroll);
    _messageController.addListener(_onComposerChanged);
    _restoreComposerDraft();
    // Native notifier: suppress notifications for this (visible) thread and
    // dismiss the ones already in the shade.
    DeepLinkService.instance
      ..setVisibleThread(widget.threadId)
      ..clearThreadNotifications(widget.threadId);
  }

  /// Keeps the send button in sync and caches the draft synchronously so the
  /// inbox shows it the moment the chat is left (see [ComposerDraftStore]).
  void _onComposerChanged() {
    _draftStore.cacheSync(
      threadId: widget.threadId,
      text: _messageController.text,
      phoneNumber: widget.phoneNumber,
      contactName: widget.contactName,
    );
    setState(() {});
  }

  /// Restores any unsent text saved for this thread when re-entering the chat,
  /// falling back to [ConversationScreen.initialText] (a forwarded body).
  Future<void> _restoreComposerDraft() async {
    final saved = await _draftStore.loadText(widget.threadId);
    if (!mounted) return;
    final text = (saved != null && saved.isNotEmpty)
        ? saved
        : (widget.initialText ?? '');
    if (text.isNotEmpty && _messageController.text.isEmpty) {
      _messageController.text = text;
      _messageController.selection = TextSelection.collapsed(
        offset: text.length,
      );
    }
  }

  /// Persists (or clears) the unsent composer text for this thread.
  void _saveComposerDraft() {
    _draftStore.save(
      threadId: widget.threadId,
      text: _messageController.text,
      phoneNumber: widget.phoneNumber,
      contactName: widget.contactName,
    );
  }

  void _onScroll() {
    if (!mounted) return;
    final pos = _scrollController.position;
    // reverse:true → offset 0 is the bottom (newest). pixels grows as the user
    // scrolls UP toward older messages.
    final shouldShow = pos.pixels > 400;
    if (shouldShow != _showScrollToBottom) {
      setState(() => _showScrollToBottom = shouldShow);
    }
    if (_isLoadingMore) return;
    final state = context.read<MessageBloc>().state;
    if (state is! MessagesLoaded || !state.hasMore) return;
    // Older messages live near the top (maxScrollExtent) now.
    if (pos.maxScrollExtent - pos.pixels <= 200) {
      _isLoadingMore = true;
      context.read<MessageBloc>().add(LoadMoreMessages(widget.threadId));
    }
  }

  @override
  void dispose() {
    DeepLinkService.instance.setVisibleThread(null);
    _saveComposerDraft();
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
    _draftStore.remove(widget.threadId);
    _messageBloc.add(SendMessage(phoneNumber: widget.phoneNumber, body: text));
  }

  void _scrollToBottom() {
    if (_scrollController.hasClients) {
      // reverse:true → the bottom (newest) is offset 0.
      _scrollController.animateTo(
        0,
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
                // reverse:true keeps the newest at offset 0; snap there only
                // when the user hasn't scrolled up (loading older messages must
                // not yank the view back to the bottom).
                if (_scrollController.hasClients && !_showScrollToBottom) {
                  _scrollController.jumpTo(0);
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
              // The thread sits on its own rounded sheet, one plane above the
              // page the header shares — Google Messages' conversation surface.
              Expanded(
                child: ClipRRect(
                  borderRadius: const BorderRadius.vertical(
                    top: Radius.circular(28),
                  ),
                  child: ColoredBox(
                    color: Theme.of(context).colorScheme.cardSurface,
                    child: _buildMessageList(),
                  ),
                ),
              ),
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

  Future<void> _openContact() async {
    if (!_hasName) {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) =>
              AddEditContactScreen(initialPhone: widget.phoneNumber),
        ),
      );
      return;
    }
    // Known contact: resolve the saved ContactModel by normalized number and
    // open its detail page; fall back to the add screen if it can't be found.
    final target = PhoneNormalizer.toThreadId(widget.phoneNumber);
    ContactModel? match;
    for (final c in await ContactRepository().getDeviceContacts()) {
      final hit = [...c.phoneNumbers, c.phoneNumber]
          .any((p) => PhoneNormalizer.toThreadId(p) == target);
      if (hit) {
        match = c;
        break;
      }
    }
    if (!mounted) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => match != null
            ? DeviceContactDetailScreen(contact: match)
            : AddEditContactScreen(initialPhone: widget.phoneNumber),
      ),
    );
  }

  // ── Message list with grouping + date separators ──────────────────────────

  Widget _buildMessageList() {
    return BlocBuilder<MessageBloc, MessageState>(
      buildWhen: (_, curr) => curr is MessageLoading || curr is MessagesLoaded,
      builder: (context, state) {
        if (state is MessageLoading) {
          return const Center(child: CircularProgressIndicator());
        }
        if (state is! MessagesLoaded) return const SizedBox.shrink();

        // Pending schedules for this thread render as ghost bubbles pinned after
        // the real messages (they are all in the future). They come from
        // ScheduledMessageBloc, so the list re-renders the moment one is sent,
        // edited or cancelled.
        return BlocBuilder<ScheduledMessageBloc, ScheduledState>(
          buildWhen: (_, curr) => curr is ScheduledLoaded,
          builder: (context, sState) {
            final scheduled = sState is ScheduledLoaded
                ? sState.pendingForThread(widget.threadId)
                : const <ScheduledMessage>[];
            final msgs = state.messages;

            if (msgs.isEmpty && scheduled.isEmpty) {
              return const Center(child: Text('هنوز پیامی نیست'));
            }

            final total = msgs.length + scheduled.length;
            // reverse:true anchors content to the BOTTOM, so a short/empty chat
            // shows its first messages at the bottom of the screen (not the top)
            // and grows upward. Render index 0 = newest (bottom); map it back to
            // the chronological data index `di` (0 = oldest).
            return ListView.builder(
              controller: _scrollController,
              reverse: true,
              padding: const EdgeInsets.symmetric(vertical: 12, horizontal: 8),
              itemCount: total,
              itemBuilder: (context, i) {
                final di = total - 1 - i;
                if (di >= msgs.length) {
                  final s = scheduled[di - msgs.length];
                  return ScheduledBubble(
                    message: s,
                    onTap: () => _showScheduledOptions(s),
                    onLongPress: () => _showScheduledOptions(s),
                  );
                }
                final msg = msgs[di];
                final prev = di > 0 ? msgs[di - 1] : null; // older
                final next = di < msgs.length - 1 ? msgs[di + 1] : null; // newer
                return _buildMessageItem(msg, prev, next);
              },
            );
          },
        );
      },
    );
  }

  // ── Scheduled-message actions ─────────────────────────────────────────────

  void _showScheduledOptions(ScheduledMessage msg) {
    final bloc = context.read<ScheduledMessageBloc>();
    showScheduledMessageOptionsSheet(
      context,
      message: msg,
      onSendNow: () => bloc.add(SendScheduledNow(msg.id)),
      onEdit: () => _editScheduled(msg),
      onCopy: () {
        Clipboard.setData(ClipboardData(text: msg.body));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('کپی شد')));
      },
      onDelete: () => _confirmCancelScheduled(msg),
    );
  }

  void _editScheduled(ScheduledMessage msg) {
    final scheduledBloc = context.read<ScheduledMessageBloc>();
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: scheduledBloc,
          child: ScheduleMessageScreen(existing: msg, settingsOnly: true),
        ),
      ),
    );
  }

  Future<void> _confirmCancelScheduled(ScheduledMessage msg) async {
    final bloc = context.read<ScheduledMessageBloc>();
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: const Text('زمان‌بندی این پیام لغو شود؟ پیام ارسال نخواهد شد.'),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('بازگشت'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text(
                'لغو زمان‌بندی',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    if (ok == true) bloc.add(DeleteScheduled(msg.id));
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
          showLinkPreview: context.watch<SettingsBloc>().state.linkPreviews,
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
      label = DateFormatter.formatChatSeparator(dt);
    }
    final theme = Theme.of(context);
    // Google Messages writes the separator as plain centred text — «دیروز •
    // ۲۳:۴۰» — with no chip behind it.
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 20, 16, 12),
      child: Center(
        child: Text(
          PersianUtils.toPersianNumber(
            '$label • ${DateFormatter.formatTime(dt)}',
          ),
          textAlign: TextAlign.center,
          style: theme.textTheme.bodySmall?.copyWith(fontSize: 13),
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
      onSelectText: () => _showSelectableText(msg),
      onForward: () => _forwardMessage(msg),
      onInfo: () => _showMessageInfo(msg),
      onSelect: () => _toggleSelect(msg.id),
      onDelete: () => _confirmDeleteMessages([msg.id]),
      isStarred: msg.isStarred,
      onToggleStar: () => _toggleStar(msg),
    );
  }

  /// Stars / unstars a message and reloads the thread so the bubble's marker
  /// updates. Local metadata only — nothing is written to the SMS provider.
  Future<void> _toggleStar(MessageModel msg) async {
    final messenger = ScaffoldMessenger.of(context);
    await MessageRepository().setStarred(msg.id, !msg.isStarred);
    if (!mounted) return;
    _messageBloc.add(LoadMessages(widget.threadId));
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          msg.isStarred ? 'از ستاره‌دارها حذف شد' : 'به ستاره‌دارها افزوده شد',
        ),
      ),
    );
  }

  /// «هدایت»: pick a recipient, then open that chat with the body already in
  /// the composer so the user can edit before sending — Google Messages'
  /// forward flow.
  Future<void> _forwardMessage(MessageModel msg) async {
    final picked = await Navigator.of(context).push<PickedRecipient>(
      MaterialPageRoute(
        builder: (_) => const ContactSelectorScreen(pickOnly: true),
      ),
    );
    if (picked == null || !mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: PhoneNormalizer.toThreadId(picked.phoneNumber),
          phoneNumber: picked.phoneNumber,
          contactName: picked.name,
          initialText: msg.body,
        ),
      ),
    );
  }

  /// Full message body in a dialog with free text selection, so part of the
  /// text can be selected and copied (the bubble's long-press is taken by the
  /// options sheet).
  void _showSelectableText(MessageModel msg) {
    showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('انتخاب متن'),
          content: SingleChildScrollView(
            child: SelectableText(
              msg.body,
              style: Theme.of(ctx).textTheme.bodyLarge,
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('بستن'),
            ),
          ],
        ),
      ),
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
            ids.length == 1
                ? 'این پیام حذف شود؟'
                : 'حذف ${PersianUtils.toPersianNumber('${ids.length}')} پیام؟',
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
      onStickerSelected: _insertSticker,
      // Long-press send → scheduler prefilled with the typed message.
      onSchedule: _openScheduler,
    );
  }

  /// Inserts an emoji at the cursor so several can be picked before sending
  /// (instead of each tap sending its own message).
  void _insertSticker(String emoji) {
    final text = _messageController.text;
    final sel = _messageController.selection;
    final start = sel.start >= 0 ? sel.start : text.length;
    final end = sel.end >= 0 ? sel.end : text.length;
    final newText = text.replaceRange(start, end, emoji);
    _messageController.value = TextEditingValue(
      text: newText,
      selection: TextSelection.collapsed(offset: start + emoji.length),
    );
  }

  void _showAttachmentSheet() {
    showAttachmentSheet(
      context,
      onInsertDraft: _insertDraft,
      onInsertTemplate: _insertTemplate,
      onSchedule: _openScheduler,
      onComingSoon: () => ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('به‌زودی'))),
    );
  }

  /// Opens the scheduler prefilled with this conversation's recipient and the
  /// current composer text. Clears the composer once the schedule is saved —
  /// the text now lives in the scheduled message, not the draft box.
  Future<void> _openScheduler() async {
    final scheduledBloc = context.read<ScheduledMessageBloc>();
    final saved = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BlocProvider.value(
          value: scheduledBloc,
          // settingsOnly: launched from inside the chat, the recipient and the
          // typed text are already known — show only the scheduling settings.
          child: ScheduleMessageScreen(
            phoneNumber: widget.phoneNumber,
            contactName: widget.contactName,
            initialBody: _messageController.text.trim(),
            settingsOnly: true,
          ),
        ),
      ),
    );
    if (saved == true && mounted) _messageController.clear();
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
