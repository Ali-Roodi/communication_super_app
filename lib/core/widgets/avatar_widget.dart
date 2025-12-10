import 'package:flutter/material.dart';
import '../utils/persian_utils.dart';

class AvatarWidget extends StatelessWidget {
  final String name;
  final double size;
  final Color? backgroundColor;

  const AvatarWidget({
    super.key,
    required this.name,
    this.size = 48,
    this.backgroundColor,
  });

  @override
  Widget build(BuildContext context) {
    final color = backgroundColor ?? PersianUtils.getAvatarColor(name);
    final initial = PersianUtils.getInitials(name);

    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
      ),
      child: Center(
        child: Text(
          initial,
          style: TextStyle(
            color: Colors.white,
            fontSize: size * 0.4,
            fontWeight: FontWeight.bold,
          ),
        ),
      ),
    );
  }
}







