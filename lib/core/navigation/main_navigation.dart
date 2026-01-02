import 'package:flutter/material.dart';
import 'package:communication_super_app/features/dialer/screens/dialer_screen.dart';
import 'package:communication_super_app/features/contacts/screens/contacts_list_screen.dart';
import 'package:communication_super_app/features/messages/screens/messages_list_screen.dart';
import 'package:communication_super_app/features/call_history/screens/call_history_screen.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

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

  final List<Widget> _screens = const [
    DialerScreen(),
    CallHistoryScreen(),
    ContactsListScreen(),
    MessagesListScreen(),
  ];

  final List<String> _titles = const [
    'شماره‌گیر',
    'تاریخچه تماس‌ها',
    'مخاطبین',
    'پیام‌ها',
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      appBar: RtlAppBar(
        title: _titles[_currentIndex],
      ),
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: Directionality(
        textDirection: TextDirection.rtl,
        child: Container(
          decoration: BoxDecoration(
            color: theme.bottomNavigationBarTheme.backgroundColor,
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.1),
                blurRadius: 8,
                offset: const Offset(0, -2),
              ),
            ],
          ),
          child: SafeArea(
            child: SizedBox(
              height: 64,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceAround,
                children: [
                  _buildNavItem(
                    context: context,
                    index: 0,
                    iconOutlined: Icons.apps_outlined,
                    iconFilled: Icons.apps,
                    label: 'شماره‌گیری',
                    theme: theme,
                  ),
                  _buildNavItem(
                    context: context,
                    index: 1,
                    iconOutlined: Icons.history_outlined,
                    iconFilled: Icons.history,
                    label: 'اخیر',
                    theme: theme,
                  ),
                  _buildNavItem(
                    context: context,
                    index: 2,
                    iconOutlined: Icons.person_outline,
                    iconFilled: Icons.person,
                    label: 'مخاطبین',
                    theme: theme,
                  ),
                  _buildNavItem(
                    context: context,
                    index: 3,
                    iconOutlined: Icons.chat_bubble_outline,
                    iconFilled: Icons.chat_bubble,
                    label: 'پیام‌ها',
                    theme: theme,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildNavItem({
    required BuildContext context,
    required int index,
    required IconData iconOutlined,
    required IconData iconFilled,
    required String label,
    required ThemeData theme,
  }) {
    final isSelected = _currentIndex == index;
    final color = isSelected
        ? theme.bottomNavigationBarTheme.selectedItemColor
        : theme.bottomNavigationBarTheme.unselectedItemColor;

    return Expanded(
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              _currentIndex = index;
            });
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                isSelected ? iconFilled : iconOutlined,
                color: color,
                size: 24,
              ),
              const SizedBox(height: 4),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: isSelected ? FontWeight.w500 : FontWeight.normal,
                  color: color,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}


