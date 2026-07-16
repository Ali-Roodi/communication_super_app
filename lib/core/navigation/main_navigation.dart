import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
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
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/core/services/deep_link_service.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/search/screens/search_screen.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';
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

  static const List<String> _titles = [
    'اخیر',
    'موردعلاقه‌ها',
    'مخاطبین',
    'پیام‌ها',
  ];

  /// Tabs that show the dialer FAB (Recents + Favorites, per Google Phone).
  bool get _showDialerFab => _currentIndex == 0 || _currentIndex == 1;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
    WidgetsBinding.instance.addObserver(this);
    // Live-refresh when the device address book changes (a contact added/edited
    // in the phone's Contacts app) so names update without an app restart.
    FlutterContacts.addListener(_refreshDeviceContacts);

    // Notification deep links: warm-start handler + the cold-start extra.
    // Registered here (post-auth) so a tap never bypasses the app lock.
    DeepLinkService.instance
      ..onOpenThread = _openThreadFromNotification
      ..registerHandler();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      final threadId = await DeepLinkService.instance.consumeInitialThreadId();
      if (threadId != null) _openThreadFromNotification(threadId);
    });
  }

  /// Opens the conversation a notification points at. The threadId IS the
  /// normalized phone number, so `forPhone` resolves it directly.
  void _openThreadFromNotification(String threadId) {
    if (!mounted) return;
    setState(() => _currentIndex = 3); // land on the Messages tab underneath
    Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => ConversationScreen.forPhone(threadId)),
    );
  }

  @override
  void dispose() {
    FlutterContacts.removeListener(_refreshDeviceContacts);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    // A contact may have been added while we were backgrounded (e.g. the user
    // switched to the phone's Contacts app and came back).
    if (state == AppLifecycleState.resumed) {
      _refreshDeviceContacts();
      // Same for calls: one may have ended (or been deleted) while
      // backgrounded — silent mirror-sync so «اخیر» is current on return.
      context.read<CallLogBloc>().add(const SyncCallLogs());
      // And for SMS: mirror-sync the provider (new/deleted rows) silently.
      context.read<MessageBloc>().add(const SyncDeviceMessages());
    }
  }

  /// Invalidates the device-contact cache and asks the contacts list + message
  /// thread names to re-resolve from the fresh data.
  void _refreshDeviceContacts() {
    if (!mounted) return;
    context.read<ContactBloc>().add(const RefreshContacts());
    context.read<MessageBloc>().add(const RefreshContactNames());
  }

  @override
  Widget build(BuildContext context) {
    // Call-screen navigation lives in CallUiCoordinator (above the auth flow,
    // see main.dart) so incoming calls surface even on the PIN screen.
    return Scaffold(
        // The Messages tab (index 3) hosts its own contextual app bar (inline
        // search, multi-select, archived menu), so the shared header is hidden
        // there to avoid a duplicate header.
        appBar: _currentIndex == 3
            ? null
            : RtlAppBar(
                title: _titles[_currentIndex],
                showSearch: true,
                showLock: false,
                onSearchPressed: () => Navigator.of(
                  context,
                ).push(MaterialPageRoute(builder: (_) => const SearchScreen())),
                actions: [
                  // 3-dot overflow menu (Google Phone style) → Settings.
                  PopupMenuButton<String>(
                    icon: const Icon(Icons.more_vert),
                    tooltip: 'گزینه‌های بیشتر',
                    onSelected: (value) {
                      if (value == 'settings') {
                        Navigator.of(context).push(
                          MaterialPageRoute(
                            builder: (_) => const SettingsScreen(),
                          ),
                        );
                      }
                    },
                    itemBuilder: (_) => const [
                      PopupMenuItem<String>(
                        value: 'settings',
                        child: Text('تنظیمات'),
                      ),
                    ],
                  ),
                ],
              ),
        drawer: null,
        floatingActionButton: _showDialerFab
            ? FloatingActionButton(
                onPressed: () => showDialerBottomSheet(context),
                backgroundColor: AppColors.callAnswerGreen,
                foregroundColor: Colors.white,
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
                onDestinationSelected: (i) {
                  setState(() => _currentIndex = i);
                },
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
