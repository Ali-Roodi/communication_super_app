import 'package:flutter/material.dart';

class AppTheme {
  // Light theme colors - from Figma design
  static const Color _lightPrimary = Color(0xFF4FC3F7); // Blue badge color
  static const Color _lightBackground = Color(0xFFFAFAFA);
  static const Color _lightSurface = Color(0xFFFFFFFF);
  static const Color _lightKeypadBackground = Color(0xFFE8E9EB);
  static const Color _lightCallButtonGreen = Color(0xFF5CB85C);
  static const Color _lightTextPrimary = Color(0xFF202124);
  static const Color _lightTextSecondary = Color(0xFF5F6368);
  static const Color _lightDivider = Color(0xFFE0E0E0);
  
  // Dark theme colors - professionally designed
  static const Color _darkPrimary = Color(0xFF64B5F6);
  static const Color _darkBackground = Color(0xFF0D0D0D);
  static const Color _darkSurface = Color(0xFF1A1A1A);
  static const Color _darkKeypadBackground = Color(0xFF242424);
  static const Color _darkCallButtonGreen = Color(0xFF66BB6A);
  static const Color _darkTextPrimary = Color(0xFFE8E8E8);
  static const Color _darkTextSecondary = Color(0xFFB0B0B0);
  static const Color _darkDivider = Color(0xFF333333);

  static ThemeData get lightTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.light,
      colorScheme: const ColorScheme.light(
        primary: _lightPrimary,
        onPrimary: Colors.white,
        secondary: _lightCallButtonGreen,
        onSecondary: Colors.white,
        surface: _lightSurface,
        onSurface: _lightTextPrimary,
        surfaceContainerHighest: _lightKeypadBackground,
        outline: _lightDivider,
      ),
      scaffoldBackgroundColor: _lightBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: _lightSurface,
        foregroundColor: _lightTextPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: _lightTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          fontFamily: 'sans-serif',
        ),
        iconTheme: IconThemeData(
          color: _lightTextSecondary,
          size: 24,
        ),
      ),
      cardTheme: CardThemeData(
        color: _lightSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: _lightSurface,
        selectedItemColor: _lightPrimary,
        unselectedItemColor: _lightTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.normal,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: _lightDivider,
        thickness: 1,
        space: 1,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: _lightTextPrimary,
        ),
        displayMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: _lightTextPrimary,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: _lightTextPrimary,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: _lightTextPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: _lightTextPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: _lightTextSecondary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: _lightTextSecondary,
        ),
      ),
    );
  }

  static ThemeData get darkTheme {
    return ThemeData(
      useMaterial3: true,
      brightness: Brightness.dark,
      colorScheme: const ColorScheme.dark(
        primary: _darkPrimary,
        onPrimary: _darkTextPrimary,
        secondary: _darkCallButtonGreen,
        onSecondary: Colors.white,
        surface: _darkSurface,
        onSurface: _darkTextPrimary,
        surfaceContainerHighest: _darkKeypadBackground,
        outline: _darkDivider,
      ),
      scaffoldBackgroundColor: _darkBackground,
      appBarTheme: const AppBarTheme(
        backgroundColor: _darkSurface,
        foregroundColor: _darkTextPrimary,
        elevation: 0,
        centerTitle: false,
        titleTextStyle: TextStyle(
          color: _darkTextPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w500,
          fontFamily: 'sans-serif',
        ),
        iconTheme: IconThemeData(
          color: _darkTextSecondary,
          size: 24,
        ),
      ),
      cardTheme: CardThemeData(
        color: _darkSurface,
        elevation: 0,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
        ),
      ),
      bottomNavigationBarTheme: const BottomNavigationBarThemeData(
        backgroundColor: _darkSurface,
        selectedItemColor: _darkPrimary,
        unselectedItemColor: _darkTextSecondary,
        type: BottomNavigationBarType.fixed,
        elevation: 8,
        selectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w500,
        ),
        unselectedLabelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.normal,
        ),
      ),
      dividerTheme: const DividerThemeData(
        color: _darkDivider,
        thickness: 1,
        space: 1,
      ),
      textTheme: const TextTheme(
        displayLarge: TextStyle(
          fontSize: 32,
          fontWeight: FontWeight.bold,
          color: _darkTextPrimary,
        ),
        displayMedium: TextStyle(
          fontSize: 24,
          fontWeight: FontWeight.bold,
          color: _darkTextPrimary,
        ),
        titleLarge: TextStyle(
          fontSize: 20,
          fontWeight: FontWeight.w600,
          color: _darkTextPrimary,
        ),
        titleMedium: TextStyle(
          fontSize: 16,
          fontWeight: FontWeight.w500,
          color: _darkTextPrimary,
        ),
        bodyLarge: TextStyle(
          fontSize: 16,
          color: _darkTextPrimary,
        ),
        bodyMedium: TextStyle(
          fontSize: 14,
          color: _darkTextSecondary,
        ),
        bodySmall: TextStyle(
          fontSize: 12,
          color: _darkTextSecondary,
        ),
      ),
    );
  }
}
