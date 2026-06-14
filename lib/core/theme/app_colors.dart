import 'package:flutter/material.dart';

/// رنگ‌های برند اپ — بر اساس Google Phone palette (Material 3)
abstract class AppColors {
  // ── Google Phone Brand ──────────────────────────────────
  static const Color googleBlue     = Color(0xFF1A73E8);
  static const Color googleBlueDark = Color(0xFF8AB4F8);

  // ── Call Actions ────────────────────────────────────────
  static const Color callAnswerGreen = Color(0xFF34A853);
  static const Color callRejectRed   = Color(0xFFEA4335);
  static const Color callHoldOrange  = Color(0xFFFBBC04);

  // ── Call Log Types ──────────────────────────────────────
  static const Color missedCallRed   = Color(0xFFEA4335);
  static const Color incomingCall    = Color(0xFF34A853);
  static const Color outgoingCall    = Color(0xFF1A73E8);
  static const Color rejectedCall    = Color(0xFFFF6D00); // orange — رد شده
  static const Color blockedCall     = Color(0xFF9AA0A6); // gray — مسدود

  // ── Light Theme ─────────────────────────────────────────
  static const Color surfaceLight      = Color(0xFFFFFFFF);
  static const Color backgroundLight   = Color(0xFFF8F9FA);
  static const Color cardLight         = Color(0xFFFFFFFF);
  static const Color dividerLight      = Color(0xFFE0E0E0);
  static const Color onSurfaceLight    = Color(0xFF202124);
  static const Color onSurfaceLightDim = Color(0xFF5F6368);
  static const Color keypadLight       = Color(0xFFE8E9EB);

  // ── Dark Theme ──────────────────────────────────────────
  static const Color surfaceDark      = Color(0xFF1A1A1A);
  static const Color backgroundDark   = Color(0xFF0D0D0D);
  static const Color cardDark         = Color(0xFF242424);
  static const Color dividerDark      = Color(0xFF333333);
  static const Color onSurfaceDark    = Color(0xFFE8E8E8);
  static const Color onSurfaceDarkDim = Color(0xFFB0B0B0);
  static const Color keypadDark       = Color(0xFF242424);
}
