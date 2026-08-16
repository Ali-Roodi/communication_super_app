import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_state.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/messages/bloc/message_event.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_bottom_sheet.dart';
import 'package:communication_super_app/features/favorites/screens/favorites_screen.dart';
import 'package:communication_super_app/features/contacts/screens/contacts_list_screen.dart';
import 'package:communication_super_app/features/messages/screens/messages_list_screen.dart';
import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/message_state.dart';
import 'package:communication_super_app/features/call_history/screens/call_history_screen.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/messages/screens/contact_selector_screen.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'widgets/message_nav_icon.dart';

class MainNavigation extends StatefulWidget {
  final int initialIndex;

  const MainNavigation({super.key, this.initialIndex = 0});

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation>
    with WidgetsBindingObserver {
  int _currentIndex = 0;

  // Tab order: Recents · Favorites · Contacts (+ Messages, kept as a 4th tab
  // since this super-app's SMS feature has no other entry point).
  // The dialer is no longer a tab — it opens from the FAB as a bottom sheet.
  static const List<Widget> _screens = [
    CallHistoryScreen(),
    FavoritesScreen(),
    ContactsListScreen(),
    MessagesListScreen(),
  ];

  static const int _recentsTab = 0;
  static const int _messagesTab = 3;

  /// Tabs that show the dialer FAB (Recents + Favorites, per Google Phone).
  bool get _showDialerFab => _currentIndex == 0 || _currentIndex == 1;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    _startAutoTabSelection();
    // Live-refresh when the device address book changes (a contact added/edited
    // in the phone's Contacts app) so names update without an app restart.
    FlutterContacts.addListener(_refreshDeviceContacts);

    // Deep links — a notification tap, or a `tel:`/`sms:` intent from another
    // app. Warm-start handler + the cold-start intent. Registered here
    // (post-auth) so nothing external can bypass the app lock.
    DeepLinkService.instance
      ..onAction = _handleLaunchAction
      ..registerHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final action = await DeepLinkService.instance.consumeInitialAction();
      if (action != null) {
        _handleLaunchAction(action);
        return;
      }
      if (_currentIndex == _recentsTab) {
        DeepLinkService.instance.clearMissedCallNotifications();
      }
      await _openDialpadIfRequested();
    });
  }

  /// Pops the keypad sheet on launch when «باز کردن صفحه‌کلید هنگام اجرای
  /// برنامه» is on.
  ///
  /// Only on a cold start (this runs from `initState`, once per process) and
  /// only when nothing else already owns the screen: a notification deep link
  /// returns before this is reached, and an incoming call arriving during
  /// launch puts its own route on top — dropping a modal sheet over a ringing
  /// call is exactly the sort of thing that leaves a phone unanswerable.
  Future<void> _openDialpadIfRequested() async {
    if (!await SettingsBloc.readShowDialpadOnStart()) return;
    if (!mounted) return;
    if (ModalRoute.of(context)?.isCurrent != true) return;
    await showDialerBottomSheet(context);
  }

  /// Opens whatever an incoming intent pointed at.
  ///
  /// Any of these is an explicit destination and beats the landing-tab
  /// heuristic below; without marking it resolved the grace timer could still
  /// swing the tab under an already-open conversation.
  void _handleLaunchAction(LaunchAction action) {
    if (!mounted) return;
    _autoTabResolved = true;
    _autoTabGrace?.cancel();

    switch (action.type) {
      case LaunchActionType.thread:
        _openThread(action.threadId);
      case LaunchActionType.sms:
        if (action.number.isEmpty) {
          // A shared text with no recipient — ask who it goes to.
          setState(() => _currentIndex = _messagesTab);
          Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ContactSelectorScreen(initialText: action.body),
            ),
          );
        } else {
          _openThread(action.number, initialText: action.body);
        }
      case LaunchActionType.dial:
        // The keypad is a modal sheet, so this is the whole of "open the
        // dialer with the number in it".
        showDialerBottomSheet(context, initialNumber: action.number);
    }
  }

  /// Switches tab, and clears the missed-call notifications when «اخیر» comes
  /// on screen — the user is now looking at the list they point at, which is
  /// where Google Phone drops them too.
  void _selectTab(int index) {
    setState(() => _currentIndex = index);
    if (index == _recentsTab) {
      DeepLinkService.instance.clearMissedCallNotifications();
    }
  }

  /// Opens a conversation. The threadId IS the normalized phone number, so
  /// `forPhone` resolves it directly.
  void _openThread(String phoneNumber, {String? initialText}) {
    setState(() => _currentIndex = _messagesTab);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) =>
            ConversationScreen.forPhone(phoneNumber, initialText: initialText),
      ),
    );
  }

  @override
  void dispose() {
    FlutterContacts.removeListener(_refreshDeviceContacts);
    WidgetsBinding.instance.removeObserver(this);
    _autoTabGrace?.cancel();
    _threadSub?.cancel();
    _callSub?.cancel();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state != AppLifecycleState.resumed) {
      // Leaving the foreground is what defines "last time the user looked".
      _markForegroundSeen();
      return;
    }
    // A contact may have been added while we were backgrounded (e.g. the user
    // switched to the phone's Contacts app and came back).
    if (state == AppLifecycleState.resumed) {
      // Coming back counts as opening the app: re-arm the landing-tab decision
      // against the moment we were last on screen.
      _startAutoTabSelection(reopen: true);
      _refreshContactsOnResume();
      // Same for calls: one may have ended (or been deleted) while
      // backgrounded — silent mirror-sync so «اخیر» is current on return.
      context.read<CallLogBloc>().add(const SyncCallLogs());
      // And for SMS: mirror-sync the provider (new/deleted rows) silently.
      context.read<MessageBloc>().add(const SyncDeviceMessages());
      if (_currentIndex == _recentsTab) {
        DeepLinkService.instance.clearMissedCallNotifications();
      }
    }
  }

  // ── Landing tab ───────────────────────────────────────────────────────────
  //
  // Opening the app when something arrived while it was away lands on that
  // something: «پیام‌ها» for a new SMS, «اخیر» for a missed call, and the newer
  // of the two when both happened. Google Phone/Messages are separate apps, so
  // neither has this problem; here the user opened the app *because* of the
  // notification and the default tab was almost never the one they wanted.
  //
  // Deliberately free of new queries: the unread totals and the call list are
  // already loaded by the two tabs (every child of the IndexedStack is mounted
  // from the start), so this only listens to state the app produces anyway.

  /// Moment the app was last in the foreground, persisted so a cold start can
  /// tell "arrived while I was away" from "arrived last week".
  static const String _lastForegroundKey = 'last_foreground_at';

  DateTime? _lastSeenAt;
  bool _autoTabResolved = false;
  Timer? _autoTabGrace;
  StreamSubscription<MessageState>? _threadSub;
  StreamSubscription<CallLogState>? _callSub;

  DateTime? _newestUnreadAt;
  DateTime? _newestMissedAt;
  bool _haveThreads = false;
  bool _haveCalls = false;

  /// How long to wait for *both* signals before deciding with whatever arrived.
  ///
  /// Picking the newer of the two needs both, but the inbox and the call log
  /// load independently and one of them may have nothing to report at all. A
  /// short grace window keeps the decision correct in the common case without
  /// ever leaving the user on a tab that a late answer would have changed —
  /// after this it is too late to move the ground under a tap anyway.
  static const Duration _autoTabGraceWindow = Duration(milliseconds: 1200);

  Future<void> _startAutoTabSelection({bool reopen = false}) async {
    _autoTabGrace?.cancel();
    _autoTabResolved = false;
    _haveThreads = false;
    _haveCalls = false;
    _newestUnreadAt = null;
    _newestMissedAt = null;

    if (!reopen) {
      // Cold start: the stored moment is the only "last seen" we have. A first
      // ever launch has none, and then nothing is "new" — leave the default tab.
      final prefs = await SharedPreferences.getInstance();
      final millis = prefs.getInt(_lastForegroundKey);
      _lastSeenAt = millis == null
          ? null
          : DateTime.fromMillisecondsSinceEpoch(millis);
    }
    if (!mounted) return;

    _threadSub?.cancel();
    _callSub?.cancel();
    final messageBloc = context.read<MessageBloc>();
    final callBloc = context.read<CallLogBloc>();
    // Seed from whatever is already loaded (a resume usually has both), then
    // follow the refresh each bloc runs on resume.
    _consumeMessageState(messageBloc.state);
    _consumeCallState(callBloc.state);
    _threadSub = messageBloc.stream.listen(_consumeMessageState);
    _callSub = callBloc.stream.listen(_consumeCallState);

    _autoTabGrace = Timer(
      _autoTabGraceWindow,
      () => _resolveAutoTab(force: true),
    );
    _resolveAutoTab();
  }

  void _consumeMessageState(MessageState state) {
    if (state is! ThreadsLoaded || state.archived) return;
    _haveThreads = true;
    DateTime? newest;
    for (final thread in state.threads) {
      if (thread.unreadCount <= 0) continue;
      if (newest == null || thread.lastMessageTime.isAfter(newest)) {
        newest = thread.lastMessageTime;
      }
    }
    _newestUnreadAt = newest;
    _resolveAutoTab();
  }

  void _consumeCallState(CallLogState state) {
    if (state is! CallLogsLoaded) return;
    _haveCalls = true;
    // The list is newest-first, so the first missed call is the newest one.
    for (final log in state.callLogs) {
      if (log.callType != CallType.missed) continue;
      _newestMissedAt = log.timestamp;
      break;
    }
    _resolveAutoTab();
  }

  void _resolveAutoTab({bool force = false}) {
    if (_autoTabResolved) return;
    if (!force && !(_haveThreads && _haveCalls)) return;

    _autoTabResolved = true;
    _autoTabGrace?.cancel();
    _threadSub?.cancel();
    _callSub?.cancel();
    _threadSub = null;
    _callSub = null;

    final seen = _lastSeenAt;
    if (seen == null) return;

    final unread = _newestUnreadAt;
    final missed = _newestMissedAt;
    final freshUnread = unread != null && unread.isAfter(seen) ? unread : null;
    final freshMissed = missed != null && missed.isAfter(seen) ? missed : null;
    if (freshUnread == null && freshMissed == null) return;

    final target =
        freshMissed == null ||
            (freshUnread != null && freshUnread.isAfter(freshMissed))
        ? _messagesTab
        : _recentsTab;
    if (mounted && _currentIndex != target) {
      _selectTab(target);
    }
  }

  /// Stamps "the user was looking at the app until now".
  void _markForegroundSeen() {
    final now = DateTime.now();
    _lastSeenAt = now;
    SharedPreferences.getInstance().then(
      (prefs) => prefs.setInt(_lastForegroundKey, now.millisecondsSinceEpoch),
      // A failed preference write only costs the landing-tab hint on the next
      // cold start; never worth an unhandled error.
      onError: (_) {},
    );
  }

  /// Minimum spacing between resume-triggered address-book re-reads.
  ///
  /// `FlutterContacts.getContacts` marshals the whole address book over the
  /// platform channel; doing that on *every* resume is why alt-tabbing back
  /// into the app stalled for seconds on a phone with thousands of contacts.
  /// An actual change to the address book still refreshes immediately through
  /// [FlutterContacts.addListener], so this only rate-limits the blind poll.
  static const Duration _contactResumeThrottle = Duration(minutes: 10);
  DateTime? _lastContactResume;

  void _refreshContactsOnResume() {
    final last = _lastContactResume;
    if (last != null &&
        DateTime.now().difference(last) < _contactResumeThrottle) {
      return;
    }
    _lastContactResume = DateTime.now();
    // Thumbnails are NOT dropped here: nothing is known to have changed, and
    // clearing them makes every visible row re-fetch its photo.
    if (!mounted) return;
    context.read<ContactBloc>().add(const RefreshContacts());
    context.read<MessageBloc>().add(const RefreshContactNames());
  }

  /// Invalidates the device-contact cache and asks the contacts list + message
  /// thread names to re-resolve from the fresh data. Wired to the address-book
  /// change listener, so it only runs when something actually changed.
  void _refreshDeviceContacts() {
    if (!mounted) return;
    LazyContactAvatar.invalidateCache();
    _lastContactResume = DateTime.now();
    context.read<ContactBloc>().add(const RefreshContacts());
    context.read<MessageBloc>().add(const RefreshContactNames());
  }

  @override
  Widget build(BuildContext context) {
    // Call-screen navigation lives in CallUiCoordinator (above the auth flow,
    // see main.dart) so incoming calls surface even on the PIN screen.
    return Scaffold(
      // No shared app bar: like Google Phone / Google Messages, every tab
      // owns its header (a search pill, or the Messages collapsing header).
      appBar: null,
      drawer: null,
      floatingActionButton: _showDialerFab
          ? FloatingActionButton(
              onPressed: () => showDialerBottomSheet(context),
              tooltip: 'شماره‌گیری',
              child: const Icon(Icons.dialpad),
            )
          : null,
      // Fade between tabs (spec: 150ms) while keeping every tab mounted so
      // scroll position and loaded state survive switching.
      body: _FadeIndexedStack(
        index: _currentIndex,
        duration: const Duration(milliseconds: 150),
        children: _screens,
      ),
      bottomNavigationBar: Directionality(
        textDirection: TextDirection.rtl,
        child: BlocBuilder<MessageBloc, MessageState>(
          // Only rebuild when the unread total changes or state type changes
          buildWhen: (prev, curr) {
            if (prev.runtimeType != curr.runtimeType) return true;
            if (curr is ThreadsLoaded && prev is ThreadsLoaded) {
              return _totalUnread(curr) != _totalUnread(prev);
            }
            return false;
          },
          builder: (context, msgState) {
            final unread = msgState is ThreadsLoaded
                ? _totalUnread(msgState)
                : 0;

            return NavigationBar(
              selectedIndex: _currentIndex,
              onDestinationSelected: _selectTab,
              destinations: [
                const NavigationDestination(
                  icon: Icon(Icons.access_time),
                  selectedIcon: Icon(Icons.access_time_filled),
                  label: 'اخیر',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.star_outline),
                  selectedIcon: Icon(Icons.star),
                  label: 'موردعلاقه‌ها',
                ),
                const NavigationDestination(
                  icon: Icon(Icons.person_outline),
                  selectedIcon: Icon(Icons.person),
                  label: 'مخاطبین',
                ),
                NavigationDestination(
                  icon: MessageNavIcon(unread: unread, filled: false),
                  selectedIcon: MessageNavIcon(unread: unread, filled: true),
                  label: 'پیام‌ها',
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  /// Sum of unread messages across all threads
  static int _totalUnread(ThreadsLoaded state) =>
      state.threads.fold(0, (sum, t) => sum + t.unreadCount);
}

// ── Fade-on-switch IndexedStack ───────────────────────────────────────────────

/// An [IndexedStack] that fades in the active child whenever [index] changes.
/// Unlike wrapping an IndexedStack in an [AnimatedSwitcher] with a per-index
/// key, this keeps the single IndexedStack (and therefore every child's State,
/// scroll position and loaded data) mounted across switches.
class _FadeIndexedStack extends StatefulWidget {
  final int index;
  final List<Widget> children;
  final Duration duration;

  const _FadeIndexedStack({
    required this.index,
    required this.children,
    required this.duration,
  });

  @override
  State<_FadeIndexedStack> createState() => _FadeIndexedStackState();
}

class _FadeIndexedStackState extends State<_FadeIndexedStack>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: widget.duration,
    value: 1,
  );

  @override
  void didUpdateWidget(_FadeIndexedStack oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.index != widget.index) {
      _controller.forward(from: 0);
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: _controller,
      child: IndexedStack(index: widget.index, children: widget.children),
    );
  }
}
