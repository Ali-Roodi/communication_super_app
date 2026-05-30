import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_bottom_sheet.dart';
import 'package:communication_super_app/features/dialer/screens/incoming_call_screen.dart';
import 'package:communication_super_app/features/dialer/screens/in_call_screen.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/favorites/screens/favorites_screen.dart';
import 'package:communication_super_app/features/contacts/screens/contacts_list_screen.dart';
import 'package:communication_super_app/features/messages/screens/messages_list_screen.dart';
import 'package:communication_super_app/features/messages/bloc/message_bloc.dart';
import 'package:communication_super_app/features/messages/bloc/message_state.dart';
import 'package:communication_super_app/features/call_history/screens/call_history_screen.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/search/screens/search_screen.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/settings/screens/settings_screen.dart';

class MainNavigation extends StatefulWidget {
  final int initialIndex;

  const MainNavigation({
    super.key,
    this.initialIndex = 0,
  });

  @override
  State<MainNavigation> createState() => _MainNavigationState();
}

class _MainNavigationState extends State<MainNavigation> {
  int _currentIndex = 0;

  // Google Phone tab order: Favorites · Recents · Contacts (+ Messages, kept as
  // a 4th tab since this super-app's SMS feature has no other entry point).
  // The dialer is no longer a tab — it opens from the FAB as a bottom sheet.
  static const List<Widget> _screens = [
    FavoritesScreen(),
    CallHistoryScreen(),
    ContactsListScreen(),
    MessagesListScreen(),
  ];

  static const List<String> _titles = [
    'موردعلاقه‌ها',
    'تلفن',
    'مخاطبین',
    'پیام‌ها',
  ];

  /// Tabs that show the dialer FAB (Favorites + Recents, per Google Phone).
  bool get _showDialerFab => _currentIndex == 0 || _currentIndex == 1;

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    // PHASE-2 VoIP: this listener navigates to IncomingCallScreen / InCallScreen
    // when callStatus changes. For cellular calls (Option A) callStatus stays
    // idle and the native system dialer manages the UI — so this never fires.
    return BlocListener<DialerBloc, DialerState>(
      listenWhen: (prev, curr) => prev.callStatus != curr.callStatus,
      listener: (context, state) {
        switch (state.callStatus) {
          case CallStatus.incoming:
            Navigator.of(context).push(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => BlocProvider.value(
                  value: context.read<DialerBloc>(),
                  child: IncomingCallScreen(phone: state.activePhone),
                ),
              ),
            );
          case CallStatus.active:
            Navigator.of(context).pushReplacement(
              MaterialPageRoute(
                fullscreenDialog: true,
                builder: (_) => BlocProvider.value(
                  value: context.read<DialerBloc>(),
                  child: InCallScreen(phone: state.activePhone),
                ),
              ),
            );
          case CallStatus.idle:
            if (Navigator.of(context).canPop()) {
              Navigator.of(context).pop();
            }
          default:
            break;
        }
      },
      child: Scaffold(
        appBar: RtlAppBar(
          title: _titles[_currentIndex],
          showSearch: true,
          showLock: false,
          onSearchPressed: () => Navigator.of(context).push(
            MaterialPageRoute(builder: (_) => const SearchScreen()),
          ),
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
        body: AnimatedSwitcher(
          duration: const Duration(milliseconds: 150),
          // Fade between tabs (spec: 150ms). The IndexedStack keeps every tab
          // mounted; keying by index lets the switcher cross-fade on change.
          child: IndexedStack(
            key: ValueKey<int>(_currentIndex),
            index: _currentIndex,
            children: _screens,
          ),
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
                    icon: Icon(Icons.star_outline),
                    selectedIcon: Icon(Icons.star),
                    label: 'موردعلاقه‌ها',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.access_time),
                    selectedIcon: Icon(Icons.access_time_filled),
                    label: 'اخیر',
                  ),
                  const NavigationDestination(
                    icon: Icon(Icons.person_outline),
                    selectedIcon: Icon(Icons.person),
                    label: 'مخاطبین',
                  ),
                  NavigationDestination(
                    icon: _MessageNavIcon(unread: unread, filled: false),
                    selectedIcon: _MessageNavIcon(unread: unread, filled: true),
                    label: 'پیام‌ها',
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }

  /// Sum of unread messages across all threads
  static int _totalUnread(ThreadsLoaded state) =>
      state.threads.fold(0, (sum, t) => sum + t.unreadCount);
}

// ── Message nav icon with unread badge ───────────────────────────────────────

class _MessageNavIcon extends StatelessWidget {
  final int unread;
  final bool filled;

  const _MessageNavIcon({required this.unread, required this.filled});

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: unread > 0,
      label: Text(unread > 99 ? '99+' : '$unread'),
      child: Icon(
        filled ? Icons.chat_bubble : Icons.chat_bubble_outline,
      ),
    );
  }
}
