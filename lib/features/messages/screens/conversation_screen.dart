import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/composer_draft_store.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'package:communication_super_app/core/services/location_service.dart';
import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../bloc/message_state.dart';
import '../models/message_model.dart';
import '../repositories/message_repository.dart';
import '../repositories/thread_sim_repository.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';
import 'package:communication_super_app/features/settings/models/blocked_number_model.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../bloc/scheduled_state.dart';
import '../models/scheduled_message_model.dart';
import '../models/template_wire.dart';
import 'drafts_list_screen.dart';
import 'templates_list_screen.dart';
import 'widgets/message_bubble.dart';
import 'contact_selector_screen.dart';
import 'widgets/conversation_app_bars.dart';
import 'widgets/conversation_sheets.dart';
import 'widgets/message_action_overlay.dart';
import 'widgets/message_composer.dart';
import 'widgets/schedule_send_sheet.dart';
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

  /// Owned here (not by the composer) so the emoji button can hand focus back
  /// to the field: closing the panel has to *open the keyboard*, and only the
  /// focus node can do that.
  final FocusNode _composerFocus = FocusNode();

  bool _isLoadingMore = false;
  bool _showScrollToBottom = false;
  bool _showStickers = false;

  /// Measured system keyboard height. The emoji panel is drawn at exactly that
  /// height, so swapping between the keyboard and the panel doesn't resize the
  /// message list under the user.
  ///
  /// Static so a freshly opened conversation already knows the height instead
  /// of falling back to the default until the keyboard has been raised once.
  static double _keyboardHeight = 0;

  /// Set once the user picks a time in the «زمان‌بندی ارسال» sheet: the
  /// composer then schedules on send instead of sending now. Cleared after the
  /// schedule is saved or when the banner's ✕ is tapped.
  ScheduleChoice? _pendingSchedule;

  /// The compact template payload waiting to be sent, and the exact human text
  /// it renders to (see [TemplateWire]).
  ///
  /// The composer always shows the *text* — the user must never be looking at a
  /// payload — so the payload is only transmitted while the field still holds
  /// that text character for character. One edit and it is stale: the words on
  /// screen are what the user means to send, and the payload no longer
  /// reconstructs them.
  String? _pendingWire;
  String? _pendingWireText;

  // Per-thread unsent composer text, so leaving the chat doesn't lose it and
  // the inbox can surface it as a draft.
  //
  // Only the visible text is persisted, never the payload: a draft restored on
  // a later visit therefore goes out as plain text. That is the correct
  // outcome — the payload cannot be recovered from the text alone.
  final ComposerDraftStore _draftStore = ComposerDraftStore();

  /// SIM this conversation sends on, and whether the user chose it *here*.
  ///
  /// The flag matters because the seed is async: without it a pick made before
  /// the stored preference arrived would be overwritten by it.
  final ThreadSimRepository _threadSim = ThreadSimRepository();
  SimCard? _sim;
  bool _simPickedByUser = false;

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
    // Tapping the text field while the emoji panel is open means "I want the
    // keyboard" — close the panel so the two are never stacked.
    _composerFocus.addListener(_onComposerFocusChanged);
    _restoreComposerDraft();
    _restoreThreadSim();
    // Native notifier: suppress notifications for this (visible) thread and
    // dismiss the ones already in the shade.
    DeepLinkService.instance
      ..setVisibleThread(widget.threadId)
      ..clearThreadNotifications(widget.threadId);
  }

  /// Seeds the composer's SIM: what this conversation last sent on, else the
  /// system default, else (dual SIM, «هر بار بپرس») nothing — an unset chip
  /// that asks, rather than a chip naming a card the send would not use.
  ///
  /// Seeded synchronously from the repository's in-memory mirror first so a
  /// re-opened conversation does not flash an unset chip for one frame.
  Future<void> _restoreThreadSim() async {
    _sim = ThreadSimRepository.cachedSimFor(widget.threadId);
    final resolved = await _threadSim.initialSimFor(widget.threadId);
    if (!mounted || _simPickedByUser) return;
    setState(() => _sim = resolved);
  }

  Future<void> _pickSim() async {
    final chosen = await showSimPicker(
      context,
      title: 'ارسال با کدام سیم‌کارت؟',
      subtitle: _title,
      selected: _sim,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _sim = chosen;
      // A later async seed must not undo an explicit choice.
      _simPickedByUser = true;
    });
  }

  void _onComposerFocusChanged() {
    if (_composerFocus.hasFocus && _showStickers) {
      setState(() => _showStickers = false);
    }
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
    _composerFocus.removeListener(_onComposerFocusChanged);
    _messageController.dispose();
    _scrollController.dispose();
    _composerFocus.dispose();
    _messageBloc.add(const LoadThreads());
    super.dispose();
  }

  /// What actually goes over the air for the [visible] composer text: the
  /// compact template payload when it is still the payload *for that exact
  /// text*, otherwise the text itself.
  String _outgoingBody(String visible) {
    final wire = _pendingWire;
    return (wire != null && visible == _pendingWireText) ? wire : visible;
  }

  void _clearPendingWire() {
    _pendingWire = null;
    _pendingWireText = null;
  }

  void _sendMessage() {
    final text = _messageController.text.trim();
    if (text.isEmpty) return;
    final body = _outgoingBody(text);
    // Armed with a time (long-press send → «زمان‌بندی ارسال») the same button
    // schedules instead of sending, the way Google Messages does it. The
    // scheduled row stores the resolved body, so a scheduled template travels
    // compact too.
    final schedule = _pendingSchedule;
    if (schedule != null) {
      _scheduleMessage(body, schedule);
      return;
    }
    _messageController.clear();
    _draftStore.remove(widget.threadId);
    _clearPendingWire();
    _messageBloc.add(
      SendMessage(
        phoneNumber: widget.phoneNumber,
        body: body,
        subscriptionId: _sim?.subscriptionId,
      ),
    );
  }

  void _scheduleMessage(String body, ScheduleChoice schedule) {
    context.read<ScheduledMessageBloc>().add(
      SaveScheduled(
        phoneNumber: widget.phoneNumber,
        contactName: widget.contactName,
        body: body,
        scheduledAt: schedule.at,
        repeat: schedule.repeat,
        repeatEvery: schedule.repeatEvery,
        weekdays: schedule.weekdays,
        jitter: schedule.jitter,
        endType: schedule.endType,
        endDate: schedule.endDate,
        maxOccurrences: schedule.maxOccurrences,
        // A scheduled message goes out on the conversation's SIM too — it is
        // delivered by a worker that has no composer to ask.
        subscriptionId: _sim?.subscriptionId,
      ),
    );
    _messageController.clear();
    _draftStore.remove(widget.threadId);
    _clearPendingWire();
    setState(() => _pendingSchedule = null);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('ارسال در ${formatScheduleLabel(schedule.at)}')),
    );
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
    // Remember how tall the system keyboard is while it is up, so the emoji
    // panel can take exactly its place. Assigned without setState on purpose:
    // it is only ever read on a later build (opening the panel is itself a
    // setState), and calling setState from build would loop.
    //
    // Two guards, both load-bearing. The inset is animated, so it reports every
    // value on the way *down* too: recording those meant the second time the
    // panel was opened it took the height of some mid-dismissal frame (~130 px)
    // instead of the keyboard's. Only a rising inset, and only while the field
    // actually holds focus (the panel closes the keyboard, so a shrinking inset
    // with no focus is a dismissal, never a measurement), is the keyboard.
    final inset = MediaQuery.viewInsetsOf(context).bottom;
    if (inset > _keyboardHeight && _composerFocus.hasFocus) {
      _keyboardHeight = inset;
    }

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
              _buildSpamPrompt(context),
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

  // ── «آیا این هرزنامه است؟» ────────────────────────────────────────────────
  //
  // Google Messages offers the report *in the conversation it is about*, on a
  // number the user has no contact for — not only buried in the overflow menu.
  // That placement is the whole point: the moment someone decides a message is
  // junk is while they are looking at it.
  //
  // Shown only for an unsaved number that has actually written to us, and only
  // until it is answered (either way) — a prompt that comes back after «این
  // هرزنامه نیست» is nagging, so the dismissal lasts for this visit.

  bool _spamPromptDismissed = false;

  Widget _buildSpamPrompt(BuildContext context) {
    if (_hasName || _spamPromptDismissed || _selectionMode) {
      return const SizedBox.shrink();
    }
    // Already blocked: the thread is in «هرزنامه و مسدودشده», nothing to ask.
    final blocked = context
        .watch<BlockedNumbersBloc>()
        .state
        .isBlocked(BlockedNumberModel.normalize(widget.phoneNumber));
    if (blocked) return const SizedBox.shrink();

    final state = context.read<MessageBloc>().state;
    final received =
        state is MessagesLoaded &&
        state.threadId == widget.threadId &&
        state.messages.any((m) => m.type == MessageType.received);
    if (!received) return const SizedBox.shrink();

    final scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsets.fromLTRB(16, 12, 8, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          Icon(Icons.shield_outlined, size: 20, color: scheme.onSurfaceVariant),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              'این شماره در مخاطبین شما نیست. هرزنامه است؟',
              style: Theme.of(context).textTheme.bodyMedium,
            ),
          ),
          TextButton(
            onPressed: () => setState(() => _spamPromptDismissed = true),
            child: const Text('نه'),
          ),
          TextButton(
            onPressed: () {
              setState(() => _spamPromptDismissed = true);
              // Captured before the await: the pop happens after the dialog and
              // the snack bar, by which time `context` is a lint hazard even
              // though the State is still mounted.
              final navigator = Navigator.of(context);
              blockNumberWithConfirm(
                context,
                phoneNumber: widget.phoneNumber,
              ).then((blocked) {
                if (blocked && mounted) navigator.pop();
              });
            },
            child: Text(
              'گزارش هرزنامه',
              style: TextStyle(color: scheme.error),
            ),
          ),
        ],
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
      onCall: () => placeCall(context, widget.phoneNumber),
      onCallPickingSim: SimService.isMultiSim
          ? () => placeCallPickingSim(context, widget.phoneNumber)
          : null,
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
        // Asks once, folds the spam report into the same question, and leaves
        // the conversation: blocking moves it out of the inbox into «هرزنامه و
        // مسدودشده», so staying here would show a thread the list no longer has.
        final navigator = Navigator.of(context);
        blockNumberWithConfirm(
          context,
          phoneNumber: widget.phoneNumber,
          contactName: _hasName ? widget.contactName : null,
        ).then((blocked) {
          if (blocked && mounted) navigator.pop();
        });
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
    // Indexed lookup — see ContactRepository._numberLookup.
    final match = await ContactRepository().getContactByPhoneNumber(
      widget.phoneNumber,
    );
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

        // Read once for the whole list. Inside the item builder this was a
        // `context.watch` per bubble: every visible bubble registered its own
        // dependency on SettingsBloc, so any unrelated settings emit rebuilt the
        // entire viewport.
        final showLinkPreview = context.select<SettingsBloc, bool>(
          (bloc) => bloc.state.linkPreviews,
        );

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
                final next = di < msgs.length - 1
                    ? msgs[di + 1]
                    : null; // newer
                return _buildMessageItem(
                  msg,
                  prev,
                  next,
                  showLinkPreview: showLinkPreview,
                );
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
      onReschedule: () => _rescheduleScheduled(msg),
      onCopy: () {
        // A scheduled template row stores the wire payload, so copy what the
        // message will *read* as.
        Clipboard.setData(
          ClipboardData(text: TemplateWire.displayText(msg.body)),
        );
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('کپی شد')));
      },
      onDelete: () => _confirmCancelScheduled(msg),
    );
  }

  /// Re-opens the quick sheet for an already-scheduled message and saves it
  /// back under the same id — Google's «Reschedule».
  Future<void> _rescheduleScheduled(ScheduledMessage msg) async {
    final bloc = context.read<ScheduledMessageBloc>();
    final choice = await showScheduleSendSheet(
      context,
      initial: ScheduleChoice.fromMessage(msg),
    );
    if (choice == null || !mounted) return;
    bloc.add(
      SaveScheduled(
        id: msg.id,
        phoneNumber: msg.phoneNumber,
        contactName: msg.contactName,
        body: msg.body,
        scheduledAt: choice.at,
        repeat: choice.repeat,
        repeatEvery: choice.repeatEvery,
        weekdays: choice.weekdays,
        jitter: choice.jitter,
        endType: choice.endType,
        endDate: choice.endDate,
        maxOccurrences: choice.maxOccurrences,
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
          content: const Text(
            'زمان‌بندی این پیام لغو شود؟ پیام ارسال نخواهد شد.',
          ),
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
    MessageModel? next, {
    required bool showLinkPreview,
  }) {
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
          showLinkPreview: showLinkPreview,
          onTap: () {
            if (_selectionMode) _toggleSelect(msg.id);
          },
          onLongPress: (anchor) {
            if (_selectionMode) {
              _toggleSelect(msg.id);
            } else {
              _showMessageOptions(msg, anchor, isLastInGroup);
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

  /// Lifts the bubble out of the list (blurred backdrop, zoom) and hangs the
  /// Google Messages action set next to it. There is no «انتخاب متن» row: the
  /// lifted bubble is selectable, so a long-press on a word right there picks
  /// it up and the handles widen the selection.
  void _showMessageOptions(MessageModel msg, Rect anchor, bool isLastInGroup) {
    showMessageActionOverlay(
      context,
      message: msg,
      anchor: anchor,
      isLastInGroup: isLastInGroup,
      showLinkPreview: context.read<SettingsBloc>().state.linkPreviews,
      actions: [
        MessageAction(
          icon: msg.isStarred ? Icons.star : Icons.star_border,
          label: msg.isStarred ? 'حذف از ستاره‌دارها' : 'ستاره‌دار کردن',
          onSelected: () => _toggleStar(msg),
        ),
        MessageAction(
          icon: Icons.copy_outlined,
          label: 'کپی',
          onSelected: () => _copyMessage(msg),
        ),
        MessageAction(
          icon: Icons.forward_outlined,
          label: 'هدایت',
          onSelected: () => _forwardMessage(msg),
        ),
        MessageAction(
          icon: Icons.info_outline,
          label: 'اطلاعات',
          onSelected: () => _showMessageInfo(msg),
        ),
        MessageAction(
          icon: Icons.checklist,
          label: 'انتخاب',
          onSelected: () => _toggleSelect(msg.id),
        ),
        MessageAction(
          icon: Icons.delete_outline,
          label: 'حذف',
          danger: true,
          onSelected: () => _confirmDeleteMessages([msg.id]),
        ),
      ],
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
          // Forwarding carries the readable message, never the payload: the new
          // recipient's copy is composed from scratch.
          initialText: TemplateWire.displayText(msg.body),
        ),
      ),
    );
  }

  void _copyMessage(MessageModel msg) {
    Clipboard.setData(ClipboardData(text: TemplateWire.displayText(msg.body)));
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
              // Named in full here (the bubble only has room for the slot
              // number). Absent when the row never recorded a SIM, which is
              // every message from before dual-SIM support.
              if (SimService.byId(msg.subscriptionId) case final sim?) ...[
                const SizedBox(height: 8),
                Text('سیم‌کارت: ${sim.slotLabel} · ${sim.name}'),
              ],
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
        // The clipboard gets what the bubbles show, not the stored wire.
        .map((m) => TemplateWire.displayText(m.body))
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
    // The panel sits inside the composer's SafeArea, which adds the navigation
    // bar inset back underneath it — while the keyboard covers that area. Draw
    // the panel that much shorter so panel + inset lands on exactly the height
    // the keyboard had, instead of a strip taller than it.
    //
    // Plain comparison, never `clamp`: the measured height climbs through every
    // frame of the keyboard's opening animation, so it is briefly ~130 px, and
    // `clamp(220, 130)` throws (lower > upper). This runs on every build of the
    // composer, panel open or not — the throw took the whole screen white for
    // the length of the animation.
    final measured = _keyboardHeight - MediaQuery.paddingOf(context).bottom;
    final fullPanel = measured > 220 ? measured : 280.0;

    // Then subtract whatever the keyboard is *still* covering. Tapping the
    // emoji button shows the panel immediately while the keyboard slides away
    // over ~200 ms, so for those frames the composer is lifted by the residual
    // inset AND carries a full-height panel — more than the screen holds, which
    // is the RenderFlex overflow. Shrinking the panel by exactly the remaining
    // inset keeps the total constant and makes the two cross-fade in place.
    final liveInset = MediaQuery.viewInsetsOf(context).bottom;
    final panelHeight = fullPanel - liveInset > 0 ? fullPanel - liveInset : 0.0;

    return MessageComposer(
      controller: _messageController,
      focusNode: _composerFocus,
      showStickers: _showStickers,
      stickerPanelHeight: panelHeight,
      onToggleStickers: _toggleStickers,
      onAttach: _showAttachmentSheet,
      onSend: _sendMessage,
      onStickerSelected: _insertSticker,
      onStickerBackspace: _backspaceComposer,
      // Long-press send → the quick «زمان‌بندی ارسال» sheet.
      onSchedule: _armSchedule,
      scheduledAt: _pendingSchedule?.at,
      scheduleSummary: _pendingSchedule == null
          ? null
          : scheduleDetailSummary(_pendingSchedule!),
      onClearSchedule: () => setState(() => _pendingSchedule = null),
      // Tapping the banner re-opens the sheet seeded with the armed choice.
      onEditSchedule: _armSchedule,
      sim: _sim,
      // The chip itself renders nothing on a single-SIM phone; passing the
      // callback unconditionally keeps that decision in one place.
      onPickSim: _pickSim,
    );
  }

  /// Picks the time and arms the composer; the message itself is scheduled
  /// when send is pressed.
  Future<void> _armSchedule() async {
    final choice = await showScheduleSendSheet(
      context,
      initial: _pendingSchedule,
    );
    if (choice == null || !mounted) return;
    setState(() => _pendingSchedule = choice);
  }

  /// Swaps the emoji panel and the system keyboard.
  ///
  /// Closing the panel must **request focus and ask for the input view**, not
  /// merely hide the panel: the button showed a keyboard glyph but only closed
  /// the emoji grid, leaving the user with neither. `TextInput.show` is needed
  /// alongside `requestFocus` because the node can still hold focus (the field
  /// keeps its cursor while the panel is up), and a no-op focus request does
  /// not raise the keyboard.
  void _toggleStickers() {
    if (_showStickers) {
      setState(() => _showStickers = false);
      _composerFocus.requestFocus();
      SystemChannels.textInput.invokeMethod<void>('TextInput.show');
    } else {
      // Drop the keyboard first so the panel isn't stacked on top of it.
      _composerFocus.unfocus();
      setState(() => _showStickers = true);
    }
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

  /// The emoji panel's backspace: deletes one whole emoji (surrogate pair, ZWJ
  /// sequence and variation selectors included) before the cursor.
  void _backspaceComposer() {
    final value = _messageController.value;
    final text = value.text;
    final selection = value.selection;
    final end = selection.isValid ? selection.start : text.length;
    if (!selection.isCollapsed && selection.isValid) {
      _messageController.value = TextEditingValue(
        text: text.replaceRange(selection.start, selection.end, ''),
        selection: TextSelection.collapsed(offset: selection.start),
      );
      return;
    }
    if (end <= 0) return;
    var start = end - 1;
    while (start > 0) {
      final unit = text.codeUnitAt(start);
      final previous = text.codeUnitAt(start - 1);
      final pairedSurrogate =
          unit >= 0xDC00 &&
          unit <= 0xDFFF &&
          previous >= 0xD800 &&
          previous <= 0xDBFF;
      final joined = unit == 0x200D || previous == 0x200D || unit == 0xFE0F;
      if (pairedSurrogate || joined) {
        start--;
        continue;
      }
      break;
    }
    _messageController.value = TextEditingValue(
      text: text.replaceRange(start, end, ''),
      selection: TextSelection.collapsed(offset: start),
    );
  }

  void _showAttachmentSheet() {
    showAttachmentSheet(
      context,
      onInsertDraft: _insertDraft,
      onInsertTemplate: _insertTemplate,
      onSchedule: _armSchedule,
      onInsertLocation: _insertLocation,
    );
  }

  /// «موقعیت» — reads one fix and appends «lat, long» to the message being
  /// written.
  ///
  /// Text, not an attachment: this is an SMS app with MMS deliberately
  /// dropped, so the coordinates travel as characters the receiver can paste
  /// into any map. The read can take a couple of seconds on a cold GPS, hence
  /// the snack bar — silence there reads as a dead button.
  Future<void> _insertLocation() async {
    final messenger = ScaffoldMessenger.of(context);
    messenger.showSnackBar(
      const SnackBar(
        content: Text('در حال گرفتن موقعیت…'),
        duration: Duration(seconds: 20),
      ),
    );
    final result = await LocationService.instance.currentLocation();
    messenger.hideCurrentSnackBar();
    if (!mounted) return;
    if (!result.ok) {
      messenger.showSnackBar(
        SnackBar(content: Text(LocationService.messageFor(result.failure!))),
      );
      return;
    }
    _appendToComposer(result.messageText);
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
    final result = await showTemplatePicker(
      context,
      contactName: widget.contactName,
    );
    if (result == null || result.text.isEmpty) return;
    _appendToComposer(result.text);
    // Arm the payload against the text it renders to. If the composer already
    // held something, the appended result is no longer the whole message, the
    // texts differ and _outgoingBody falls back to plain text on its own.
    _pendingWire = result.wire;
    _pendingWireText = result.wire == null ? null : result.text;
  }

  void _appendToComposer(String text) {
    final existing = _messageController.text;
    _messageController.text = existing.isEmpty ? text : '$existing\n$text';
    _messageController.selection = TextSelection.fromPosition(
      TextPosition(offset: _messageController.text.length),
    );
  }
}
