import 'package:flutter/material.dart';
import '../constants/app_constants.dart';

class PersianUtils {
  static String toPersianNumber(String number) {
    String result = number;
    AppConstants.persianNumbers.forEach((english, persian) {
      result = result.replaceAll(english, persian);
    });
    return result;
  }

  static String toEnglishNumber(String number) {
    String result = number;
    AppConstants.persianNumbers.forEach((english, persian) {
      result = result.replaceAll(persian, english);
    });
    return result;
  }

  static String getInitials(String name) {
    if (name.isEmpty) return '';
    return name[0].toUpperCase();
  }

  static int getAvatarColorIndex(String name) {
    if (name.isEmpty) return 0;
    return name.codeUnitAt(0) % AppConstants.avatarColors.length;
  }

  static Color getAvatarColor(String name) {
    final index = getAvatarColorIndex(name);
    return Color(AppConstants.avatarColors[index]);
  }
}

