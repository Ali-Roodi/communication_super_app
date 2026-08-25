import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
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
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/save_number_actions.dart';
import '../bloc/scheduled_bloc.dart';
import '../bloc/scheduled_event.dart';
import '../bloc/scheduled_state.dart';
import '../models/message_group.dart';
import '../models/scheduled_message_model.dart';
import '../models/template_wire.dart';
import '../repositories/group_repository.dart';
import 'drafts_list_screen.dart';
import 'conversation_details_screen.dart';
import 'group_details_screen.dart';
import 'templates_list_screen.dart';
import 'widgets/message_bubble.dart';
import 'contact_selector_screen.dart';
import 'widgets/conversation_app_bars.dart';
import 'widgets/conversation_sheets.dart';
import 'widgets/message_action_overlay.dart';
import 'widgets/message_composer.dart';
import 'widgets/pinch_text_scale.dart';
import 'widgets/schedule_send_sheet.dart';
import 'widgets/scheduled_bubble.dart';
import 'package:communication_super_app/core/navigation/app_route_observer.dart';

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

  /// The group this conversation belongs to, when [threadId] is a group thread
  /// (`'g:…'`, see [GroupThread]).
  ///
  /// Passed in by whoever already had it (the inbox row, the picker that just
  /// created it) purely so the header paints named on the first frame; the screen
  /// re-reads it either way, because it is the details page — reachable from
  /// here — that can rename it or change who is in it.
  final MessageGroup? group;

  const ConversationScreen({
    super.key,
    required this.threadId,
    required this.phoneNumber,
    this.contactName,
    this.initialText,
    this.group,
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
       group = null,
       contactName = (contactName?.isNotEmpty ?? false) ? contactName : null;

  @override
  State<ConversationScreen> createState() => _ConversationScreenState();
}

class _ConversationScreenState extends State<ConversationScreen>
    with RouteAware {
  final TextEditingController _messageController = TextEditingController();
  final ScrollController _scrollController = ScrollController();

  /// The last [MessagesLoaded] that belongs to **this** thread.
  ///
  /// `MessageBloc` is global and holds exactly one conversation at a time, so a
  /// second chat opened on top of this one (tapping a number inside a message,
  /// «هدایت») replaces the bloc's state with *its* messages while this screen is
  /// still mounted underneath. Rendering whatever `MessagesLoaded` happened to
  /// be current is why coming back from that second chat showed the other
  /// conversation's messages under this one's header — the messages were never
  /// wrong in the database, the screen was reading somebody else's state.
  ///
  /// So: every read is filtered by [_isMine], and the last matching page is kept
  /// here to paint from while the bloc is busy with another thread.
  MessagesLoaded? _lastLoaded;

  /// Whether [state] is this conversation's own loaded page.
  bool _isMine(MessageState state) =>
      state is MessagesLoaded && state.threadId == widget.threadId;

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

  /// The contact's name, resolved from the address book when the caller did not
  /// know it.
  ///
  /// A notification deep link only carries the thread id — the number — so
  /// without this the chat opened from the shade titled itself with the number
  /// and offered «این شماره در مخاطبین شما نیست. هرزنامه است؟» about someone in
  /// the address book. It corrected itself on the next visit, because the inbox
  /// row *had* resolved the name by then, which is exactly what made it look
  /// random.
  String? _contactName;

  /// False until the address-book lookup has answered. Everything that reads
  /// "this number has no contact" waits for it, or it flashes the wrong answer
  /// for the first frames.
  bool _contactResolved = false;

  /// The group behind this conversation, when the thread is a group one.
  ///
  /// Re-read on entry and after the details page, because a rename or a member
  /// change made there has to show in the header without leaving the chat.
  MessageGroup? _group;

  /// Whether this conversation is a group. Read from the **thread id**, so it is
  /// true from the first frame even before [_group] has been read back —
  /// everything that would otherwise treat the thread id as a phone number (the
  /// call button, the spam prompt, «مشاهده مخاطب») hangs off this.
  bool get _isGroup => GroupThread.isGroup(widget.threadId);

  bool get _hasName => _contactName != null;
  String get _title {
    if (_isGroup) return _group?.displayTitle ?? 'گفتگوی گروهی';
    return _contactName ??
        PersianUtils.displayPhone(
          PhoneNormalizer.toNational(widget.phoneNumber),
        );
  }

  @override
  void initState() {
    super.initState();
    _messageBloc = context.read<MessageBloc>();
    if (_isGroup) {
      _group = widget.group;
      // The draft store and the inbox row title themselves from `contactName`;
      // for a group that is the group's name.
      _contactName = _group?.displayTitle;
      _contactResolved = true;
      _loadGroup();
      _loadGroupNoticeSeen();
    } else {
      _contactName = widget.contactName;
      _contactResolved = _contactName != null;
      _resolveContactName();
      ContactRepository.revision.addListener(_onAddressBookChanged);
    }
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
    // A conversation opened from a notification can beat the SIM roster's own
    // read (a message routinely wakes a dead process), and the seed above then
    // resolves to nothing. Re-seed when the roster lands.
    SimService.revision.addListener(_restoreThreadSim);
    // Native notifier: suppress notifications for this (visible) thread and
    // dismiss the ones already in the shade.
    DeepLinkService.instance
      ..setVisibleThread(widget.threadId)
      ..clearThreadNotifications(widget.threadId);
  }

  /// Re-reads the group behind this thread.
  ///
  /// Always, even when the caller handed one in: the caller's copy is a snapshot
  /// (an inbox row painted a minute ago), and the composer sends to whoever is in
  /// the group *now*.
  Future<void> _loadGroup() async {
    final group = await GroupRepository().getByThreadId(widget.threadId);
    if (!mounted || group == null) return;
    setState(() {
      _group = group;
      _contactName = group.displayTitle;
    });
  }

  /// Resolves the title from the address book when the caller did not carry a
  /// name — a notification deep link, a tapped number, a search hit on a raw
  /// number.
  ///
  /// Seeded synchronously from the number index when it is already built (the
  /// normal case: the inbox has been listed), so the chat opens with the name
  /// already on it instead of showing the number for a frame.
  ///
  /// [force] re-asks even when a name is already on the header — the address
  /// book changed underneath it (see [_onAddressBookChanged]), so the name it
  /// is showing is exactly the one that must not be trusted. It also has to be
  /// able to go back to *no* name: the contact may have been deleted, and the
  /// spam prompt hangs off that answer.
  Future<void> _resolveContactName({bool force = false}) async {
    if (_contactName != null && !force) return;
    final cached = ContactRepository.cachedByPhoneNumber(widget.phoneNumber);
    if (cached != null) {
      _applyResolvedName(cached.name, notify: force);
      return;
    }
    if (ContactRepository.hasNumberIndex) {
      // The index is built and this number is not in it — authoritative.
      _applyResolvedName(force ? null : _contactName, notify: true);
      return;
    }
    final match = await ContactRepository().getContactByPhoneNumber(
      widget.phoneNumber,
    );
    if (!mounted) return;
    _applyResolvedName(match?.name, notify: true);
  }

  /// Commits a resolution. [notify] is false only on the initState path, where
  /// there is no element to rebuild yet.
  void _applyResolvedName(String? name, {required bool notify}) {
    void apply() {
      _contactName = (name != null && name.isNotEmpty) ? name : null;
      _contactResolved = true;
    }

    if (notify) {
      setState(apply);
    } else {
      apply();
    }
  }

  /// The address book changed while this conversation was open — most often
  /// because the user tapped the header, renamed the contact and came back.
  ///
  /// The header used to keep the name it had resolved on entry, so the rename
  /// was invisible until the app was restarted. The number index is rebuilt
  /// lazily, so the re-resolve is deferred to the next frame rather than run
  /// against the snapshot that is being replaced.
  void _onAddressBookChanged() {
    if (!mounted || _isGroup) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _resolveContactName(force: true);
    });
  }

  /// Seeds the SIM this conversation sends on: what it last sent on, else the
  /// card the other side last *reached* it on, else the system default.
  ///
  /// The middle answer is the one a dual-SIM phone actually needs. A stranger
  /// who wrote to the second card used to be answered from the first, because
  /// nothing but the user's own past sends counted — so the reply reached them
  /// from a number they had never written to, and the native quick-reply
  /// (which has always answered on the arrival card) disagreed with the app's
  /// own composer.
  ///
  /// Seeded synchronously from the repository's in-memory mirror first so a
  /// re-opened conversation does not flash the wrong card for one frame.
  Future<void> _restoreThreadSim() async {
    _sim = ThreadSimRepository.cachedSimFor(widget.threadId);
    final resolved = await _threadSim.initialSimFor(widget.threadId);
    if (!mounted || _simPickedByUser) return;
    setState(() => _sim = resolved);
  }

  void _adoptSim(SimCard sim) {
    setState(() {
      _sim = sim;
      // A later async seed must not undo an explicit choice.
      _simPickedByUser = true;
    });
  }

  /// «جزئیات گفتگو» — Google Messages' details page, opened by tapping the
  /// header. It is where the SIM this conversation sends on is named and
  /// changed (the composer no longer carries a chip), and where archiving,
  /// blocking and deleting live.
  ///
  /// Everything that ends the conversation comes back as an outcome rather
  /// than being done there: the delete has to take the provider rows with it
  /// and this screen is the one holding the thread — the same split
  /// [GroupDetailsScreen] uses.
  Future<void> _openDetails() async {
    final result = await Navigator.of(context).push<ConversationDetailsResult>(
      MaterialPageRoute(
        builder: (_) => ConversationDetailsScreen(
          threadId: widget.threadId,
          phoneNumber: widget.phoneNumber,
          title: _title,
          contactName: _contactName,
          sim: _sim,
        ),
      ),
    );
    if (result == null || !mounted) return;
    if (result.sim case final sim?) _adoptSim(sim);
    switch (result.outcome) {
      case ConversationDetailsOutcome.none:
        break;
      case ConversationDetailsOutcome.deleted:
        _messageBloc.add(DeleteThread(widget.threadId));
        Navigator.of(context).pop();
      case ConversationDetailsOutcome.blocked:
      case ConversationDetailsOutcome.archived:
        // Both move the thread out of the inbox behind this screen.
        Navigator.of(context).pop();
    }
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
      contactName: _contactName,
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
      contactName: _contactName,
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
    if (!_isMine(state) || !(state as MessagesLoaded).hasMore) return;
    // Older messages live near the top (maxScrollExtent) now.
    if (pos.maxScrollExtent - pos.pixels <= 200) {
      _isLoadingMore = true;
      context.read<MessageBloc>().add(LoadMoreMessages(widget.threadId));
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final route = ModalRoute.of(context);
    if (route is PageRoute) appRouteObserver.subscribe(this, route);
  }

  /// A conversation opened on top of this one has been popped.
  ///
  /// Two things have to happen, and neither is optional. `MessageBloc` is now
  /// parked on the *other* thread's page, so this screen has to ask for its own
  /// again — and while that chat was open it was also the "visible thread" for
  /// the native notifier, which must be handed back here or notifications for
  /// this conversation keep being posted while the user is reading it.
  @override
  void didPopNext() {
    if (!mounted) return;
    DeepLinkService.instance
      ..setVisibleThread(widget.threadId)
      ..clearThreadNotifications(widget.threadId);
    _messageBloc.add(LoadMessages(widget.threadId));
  }

  @override
  void dispose() {
    appRouteObserver.unsubscribe(this);
    DeepLinkService.instance.setVisibleThread(null);
    ContactRepository.revision.removeListener(_onAddressBookChanged);
    SimService.revision.removeListener(_restoreThreadSim);
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
    final group = _group;
    if (_isGroup) {
      // The group is named, not its members: membership is read at send time, so
      // somebody removed on the details page a moment ago does not get the
      // message anyway.
      if (group == null) return;
      _messageBloc.add(
        SendGroupMessage(
          groupId: group.id,
          body: body,
          subscriptionId: _sim?.subscriptionId,
        ),
      );
      return;
    }
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
        contactName: _contactName,
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

    // A bubble's SIM badge is read from the *static* roster inside `build`
    // (it cannot await a channel), so a card going into the phone while this
    // chat is open is invisible to the element tree. SimAware is the dependency
    // that makes it visible.
    return SimAware(
      builder: (context, _, _) => Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: _selectionMode ? _selectionAppBar() : _normalAppBar(),
          body: BlocListener<MessageBloc, MessageState>(
            listenWhen: (_, curr) =>
                _isMine(curr) ||
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
                // Reloaded on failure too, not only on success. The bloc is
                // global and the inbox answers every send outcome with a
                // `LoadThreads`, so by the time a *second* refused send lands the
                // bloc is sitting on `ThreadsLoaded` and the fold-into-the-open-
                // conversation path gives up — the «ارسال نشد» bubble was in the
                // database but did not appear until the thread was re-opened.
                context.read<MessageBloc>().add(LoadMessages(widget.threadId));
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
            // «اندازه متن پیام»: pinch the thread to resize it, persisted and
            // shared with the Settings row. Wrapped around the thread and the
            // composer but NOT the app bar — a title at 200% breaks the header's
            // layout, and Google Messages does not scale its chrome either.
            child: PinchTextScale(
              scale: context.select<SettingsBloc, double>(
                (b) => b.state.messageTextScale,
              ),
              onScaleChanged: (scale) =>
                  context.read<SettingsBloc>().add(SetMessageTextScale(scale)),
              child: Column(
                children: [
                  _buildGroupNotice(context),
                  _buildSpamPrompt(context),
                  // The thread sits on its own rounded sheet, one plane above the
                  // page the header shares — Google Messages' conversation
                  // surface.
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
          ),
          floatingActionButton: _showScrollToBottom && !_selectionMode
              ? FloatingActionButton.small(
                  heroTag: 'scroll_bottom',
                  onPressed: _scrollToBottom,
                  child: const Icon(Icons.keyboard_arrow_down),
                )
              : null,
        ),
      ),
    );
  }

  // ── «پاسخ‌ها کجا می‌آید؟» ──────────────────────────────────────────────────
  //
  // Without MMS there is no provider thread that can hold several recipients, so
  // a group send is N separate messages and every answer lands in that person's
  // own conversation. That is not a detail to leave the user to discover: the
  // first thing anyone does in a group chat is expect a reply in it.
  //
  // Said **once**, not on every visit — a banner that comes back for ever is
  // furniture. It is dismissed for the app, not for this group, because it is a
  // fact about the app rather than about these people.

  static const String _kGroupNoticeKey = 'group_sms_notice_seen_v1';

  /// Null until the preference has been read; the banner does not flash in and
  /// out while that happens.
  bool? _groupNoticeSeen;

  Future<void> _loadGroupNoticeSeen() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool(_kGroupNoticeKey) ?? false;
    if (!mounted) return;
    setState(() => _groupNoticeSeen = seen);
  }

  Future<void> _dismissGroupNotice() async {
    setState(() => _groupNoticeSeen = true);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGroupNoticeKey, true);
  }

  Widget _buildGroupNotice(BuildContext context) {
    if (!_isGroup || _selectionMode) return const SizedBox.shrink();
    if (_groupNoticeSeen != false) return const SizedBox.shrink();
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
      padding: const EdgeInsetsDirectional.fromSTEB(16, 12, 8, 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(16),
      ),
      // Column, not a Row with the button on the end: the sentence needs three
      // lines on a phone, and a button vertically centred against them lands
      // between the lines and reads as part of the paragraph.
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(
                Icons.groups_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'پیام شما جداگانه برای هر عضو ارسال می‌شود و پاسخ هر نفر در '
                  'گفتگوی خودش می‌آید.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
          Align(
            alignment: AlignmentDirectional.centerEnd,
            child: TextButton(
              onPressed: _dismissGroupNotice,
              child: const Text('متوجه شدم'),
            ),
          ),
        ],
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
    // A group has no sender to report and no number to block — the members are
    // people the user picked themselves.
    if (_isGroup) return const SizedBox.shrink();
    // `_contactResolved` is the load-bearing half: opened from a notification
    // this screen starts with nothing but the number, and asking «هرزنامه
    // است؟» about a saved contact for the first frames is exactly the bug this
    // guard exists for.
    if (!_contactResolved ||
        _hasName ||
        _spamPromptDismissed ||
        _selectionMode) {
      return const SizedBox.shrink();
    }
    // Already blocked: the thread is in «هرزنامه و مسدودشده», nothing to ask.
    final blocked = context.watch<BlockedNumbersBloc>().state.isBlocked(
      BlockedNumberModel.normalize(widget.phoneNumber),
    );
    if (blocked) return const SizedBox.shrink();

    final state = context.read<MessageBloc>().state;
    final received =
        _isMine(state) &&
        (state as MessagesLoaded).messages.any(
          (m) => m.type == MessageType.received,
        );
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
            child: Text('گزارش هرزنامه', style: TextStyle(color: scheme.error)),
          ),
        ],
      ),
    );
  }

  // ── App bars ──────────────────────────────────────────────────────────────

  PreferredSizeWidget _normalAppBar() {
    if (_isGroup) {
      return GroupConversationAppBar(
        title: _title,
        subtitle: _group?.memberCountLabel ?? '',
        onOpenDetails: _openGroupDetails,
        onMenuSelected: _onGroupMenu,
      );
    }
    return ConversationAppBar(
      title: _title,
      phoneNumber: widget.phoneNumber,
      hasName: _hasName,
      onOpenContact: _openDetails,
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

  void _onGroupMenu(String value) {
    switch (value) {
      case 'details':
        _openGroupDetails();
      case 'textSize':
        showMessageTextSizeSheet(context);
      case 'delete':
        _confirmDeleteConversation();
    }
  }

  /// «جزئیات گروه» — the one page that can rename the group or change who is in
  /// it. Deleting from there comes back as a result rather than doing the delete
  /// itself, because the delete is a *conversation* operation (provider rows
  /// included) and this screen is the one holding the thread.
  Future<void> _openGroupDetails() async {
    final group = _group;
    if (group == null) return;
    final result = await Navigator.of(context).push<GroupDetailsResult>(
      MaterialPageRoute(builder: (_) => GroupDetailsScreen(group: group)),
    );
    if (result == null || !mounted) return;
    if (result.deleted) {
      _messageBloc.add(DeleteThread(widget.threadId));
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _group = result.group;
      _contactName = result.group.displayTitle;
    });
  }

  void _onMenu(String value) {
    switch (value) {
      case 'view':
        _openContact();
      case 'add':
        _addContact();
      case 'addExisting':
        addNumberToExistingContact(context, widget.phoneNumber).then((saved) {
          if (saved && mounted) _resolveContactName();
        });
      case 'textSize':
        showMessageTextSizeSheet(context);
      case 'block':
        // Asks once, folds the spam report into the same question, and leaves
        // the conversation: blocking moves it out of the inbox into «هرزنامه و
        // مسدودشده», so staying here would show a thread the list no longer has.
        final navigator = Navigator.of(context);
        blockNumberWithConfirm(
          context,
          phoneNumber: widget.phoneNumber,
          contactName: _contactName,
        ).then((blocked) {
          if (blocked && mounted) navigator.pop();
        });
      case 'delete':
        _confirmDeleteConversation();
    }
  }

  /// «افزودن مخاطب»: saving one here has to re-title this screen — it is the
  /// same number, and the header would otherwise keep showing it as unsaved
  /// (spam prompt included) until the chat was left and re-entered.
  Future<void> _addContact() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditContactScreen(initialPhone: widget.phoneNumber),
      ),
    );
    if (!mounted) return;
    await _resolveContactName(force: true);
  }

  Future<void> _openContact() async {
    if (!_hasName) {
      await _addContact();
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
      // `MessagesLoaded` for ANOTHER thread is not this screen's news: the bloc
      // is global, and a chat opened on top of this one parks it on that
      // conversation. See [_lastLoaded].
      buildWhen: (_, curr) => curr is MessageLoading || _isMine(curr),
      builder: (context, rawState) {
        if (_isMine(rawState)) _lastLoaded = rawState as MessagesLoaded;
        final state = _lastLoaded;
        // A spinner only while there is genuinely nothing of this thread to
        // paint — never over a page already on screen.
        if (state == null) {
          return const Center(child: CircularProgressIndicator());
        }

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
    final selected = _selected.contains(msg.id);

    return Column(
      children: [
        if (showDateSep) _dateSeparator(msg.timestamp),
        MessageBubble(
          message: msg,
          isLastInGroup: isLastInGroup,
          expanded: _expandedMessageId == msg.id,
          selected: selected,
          selectionMode: _selectionMode,
          showLinkPreview: showLinkPreview,
          onTap: () {
            if (_selectionMode) {
              _toggleSelect(msg.id);
            } else {
              _toggleExpanded(msg.id);
            }
          },
          onLongPress: (anchor) {
            if (_selectionMode) {
              _toggleSelect(msg.id);
            } else {
              _showMessageOptions(msg, anchor, isLastInGroup);
            }
          },
          // Re-sends the row that is already there (same id, same place in the
          // thread). It used to dispatch a fresh `SendMessage`, which left the
          // failed bubble behind and put a second copy under it.
          onRetry: msg.status == MessageStatus.failed
              ? () => _messageBloc.add(RetryMessage(msg.id))
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

  /// Which message is showing its own time + delivery state, or null.
  ///
  /// One at a time, like Google Messages: opening a second closes the first, so
  /// the chat never fills up with status rows the user has to close one by one.
  String? _expandedMessageId;

  void _toggleExpanded(String id) {
    setState(() => _expandedMessageId = _expandedMessageId == id ? null : id);
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
        // First, and only on a message that failed: it is the one thing anyone
        // wants from such a bubble, and it is what Google Messages puts at the
        // top of the same menu.
        if (msg.type == MessageType.sent && msg.status == MessageStatus.failed)
          MessageAction(
            icon: Icons.refresh,
            label: 'ارسال مجدد',
            onSelected: () => _messageBloc.add(RetryMessage(msg.id)),
          ),
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

  /// «اطلاعات» on a **group** bubble: one line per recipient.
  ///
  /// The bubble can only show one tick for N outcomes, and the fold is
  /// deliberately pessimistic — so this is where "who actually got it" is
  /// answered, and where a partial failure names the people to try again for.
  Future<void> _showGroupMessageInfo(MessageModel msg) async {
    final targets = await GroupRepository().targetsOf(msg.id);
    if (!mounted) return;
    if (targets.isEmpty) {
      _showMessageInfo(msg, groupChecked: true);
      return;
    }
    final summary = GroupSendSummary.of(targets);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('اطلاعات پیام'),
          content: SizedBox(
            width: double.maxFinite,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text('زمان: ${DateFormatter.formatDateTime(msg.timestamp)}'),
                const SizedBox(height: 4),
                Text(summary.label),
                const SizedBox(height: 12),
                Flexible(
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: targets.length,
                    itemBuilder: (_, i) {
                      final target = targets[i];
                      final member = _group?.members.firstWhere(
                        (m) => m.normalized == target.normalized,
                        orElse: () =>
                            GroupMember(phoneNumber: target.phoneNumber),
                      );
                      return ListTile(
                        dense: true,
                        contentPadding: EdgeInsets.zero,
                        title: Text(
                          member?.label ??
                              PersianUtils.displayPhone(
                                PhoneNormalizer.toNational(target.phoneNumber),
                              ),
                        ),
                        trailing: Text(
                          switch (target.status) {
                            'pending' => 'در حال ارسال',
                            'delivered' => 'تحویل‌شده',
                            'failed' => 'ناموفق',
                            _ => 'ارسال‌شده',
                          },
                          style: TextStyle(
                            color: target.failed
                                ? Theme.of(ctx).colorScheme.error
                                : Theme.of(ctx).colorScheme.onSurfaceVariant,
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
            ),
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

  void _showMessageInfo(MessageModel msg, {bool groupChecked = false}) {
    // A group message has N outcomes, not one — they live in their own dialog.
    if (_isGroup && !groupChecked) {
      _showGroupMessageInfo(msg);
      return;
    }
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
    final state = _lastLoaded;
    if (state == null) return;
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
      //
      // Off in a group: a `scheduled_messages` row carries **one** phone number
      // and is delivered by a native worker that knows nothing about groups, so
      // an armed group schedule would fire as a single SMS to a thread id. The
      // affordance is withheld rather than accepted and quietly mishandled.
      onSchedule: _isGroup ? null : _armSchedule,
      scheduledAt: _pendingSchedule?.at,
      scheduleSummary: _pendingSchedule == null
          ? null
          : scheduleDetailSummary(_pendingSchedule!),
      onClearSchedule: () => setState(() => _pendingSchedule = null),
      // Tapping the banner re-opens the sheet seeded with the armed choice.
      onEditSchedule: _armSchedule,
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
      onSchedule: _isGroup ? null : _armSchedule,
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
    final result = await showTemplatePicker(context, contactName: _contactName);
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
