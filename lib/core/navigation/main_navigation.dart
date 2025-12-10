import 'package:flutter/material.dart';
import 'package:communication_super_app/features/dialer/screens/dialer_screen.dart';
import 'package:communication_super_app/features/contacts/screens/contacts_list_screen.dart';
import 'package:communication_super_app/features/messages/screens/messages_list_screen.dart';
import 'package:communication_super_app/features/call_history/screens/call_history_screen.dart';

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

  final List<Widget> _screens = [
    const MessagesListScreen(),
    const ContactsListScreen(),
    const CallHistoryScreen(),
    const DialerScreen(),
  ];

  @override
  void initState() {
    super.initState();
    _currentIndex = widget.initialIndex;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: IndexedStack(
        index: _currentIndex,
        children: _screens,
      ),
      bottomNavigationBar: BottomNavigationBar(
        currentIndex: _currentIndex,
        onTap: (index) {
          setState(() {
            _currentIndex = index;
          });
        },
        type: BottomNavigationBarType.fixed,
        items: const [
          BottomNavigationBarItem(
            icon: Icon(Icons.message),
            label: 'پیام ها',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.person),
            label: 'مخاطبین',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.history),
            label: 'اخير',
          ),
          BottomNavigationBarItem(
            icon: Icon(Icons.dialpad),
            label: 'شماره گیری',
          ),
        ],
      ),
    );
  }
}


