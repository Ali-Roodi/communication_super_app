import 'package:flutter/material.dart';

/// A bottom-nav icon with a count [Badge]: hidden at 0, capped at "99+".
class NavCountIcon extends StatelessWidget {
  final int count;
  final IconData icon;

  const NavCountIcon({super.key, required this.count, required this.icon});

  @override
  Widget build(BuildContext context) {
    return Badge(
      isLabelVisible: count > 0,
      label: Text(count > 99 ? '99+' : '$count'),
      child: Icon(icon),
    );
  }
}
