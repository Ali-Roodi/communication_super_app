import 'package:flutter/material.dart';

class AppLockWrapper extends StatelessWidget {
  final Widget child;

  const AppLockWrapper({super.key, required this.child});

  @override
  Widget build(BuildContext context) {
    return child;
  }
}
