import 'package:flutter/material.dart';

/// رنگ‌های برند اپ — استخراج‌شده از فایل Figma «هم‌رسان» (Design System).
///
/// پالت اصلی: لاجوردی روشن (#00A6ED) + متن طوسی‌آبی (#334A52).
/// نام‌های قدیمی (googleBlue و …) برای سازگاری حفظ شده‌اند اما مقدارشان
/// به توکن‌های Figma به‌روزرسانی شده تا کل اپ هم‌زمان هم‌رنگ شود.
abstract class AppColors {
  // ── Figma Design Tokens ─────────────────────────────────
  /// رنگ اصلی برند / accent — Info-100
  static const Color accent = Color(0xFF00A6ED);

  /// نسخه روشن‌تر برای حالت تاریک
  static const Color accentLight = Color(0xFF45BDEF);

  /// لاجوردی تیره — Gradient-100 (هدر/عناصر عمیق)
  static const Color accentDeep = Color(0xFF004455);

  /// خطر / لغو / خطا — Danger-100
  static const Color danger = Color(0xFFEC0206);

  /// متن اصلی — Gray/Text
  static const Color textPrimary = Color(0xFF334A52);

  /// متن ثانویه / آیکون غیرفعال — Gray-100
  static const Color textSecondary = Color(0xFF96AFB8);

  /// طوسی روشن — Gray-50 (جداکننده / غیرفعال)
  static const Color gray50 = Color(0xFFCBD7DB);
  static const Color gray100 = Color(0xFF96AFB8);

  // ── Brand aliases (سازگاری با کد موجود) ─────────────────
  static const Color googleBlue = accent; // #00A6ED
  static const Color googleBlueDark = accentLight; // #45BDEF

  // ── Call Actions ────────────────────────────────────────
  static const Color callAnswerGreen = Color(0xFF34A853);
  static const Color callRejectRed = danger;
  static const Color callHoldOrange = Color(0xFFFBBC04);

  // ── Call Log Types ──────────────────────────────────────
  static const Color missedCallRed = danger;
  static const Color incomingCall = Color(0xFF34A853);
  static const Color outgoingCall = accent;
  static const Color rejectedCall = Color(0xFFFF6D00); // orange — رد شده
  static const Color blockedCall = Color(0xFF96AFB8); // gray — مسدود

  // ── Light Theme ─────────────────────────────────────────
  static const Color surfaceLight = Color(0xFFFFFFFF);
  static const Color backgroundLight = Color(0xFFF7FAFB);
  static const Color cardLight = Color(0xFFFFFFFF);
  static const Color dividerLight = Color(0xFFE3EAED);
  static const Color onSurfaceLight = textPrimary; // #334A52
  static const Color onSurfaceLightDim = textSecondary; // #96AFB8
  static const Color keypadLight = Color(0xFFF1F5F7);

  // ── Dark Theme ──────────────────────────────────────────
  static const Color surfaceDark = Color(0xFF14242B); // طوسی‌آبی تیره
  static const Color backgroundDark = Color(0xFF0C171B);
  static const Color cardDark = Color(0xFF1B2E36);
  static const Color dividerDark = Color(0xFF2A3D45);
  static const Color onSurfaceDark = Color(0xFFE6EEF1);
  static const Color onSurfaceDarkDim = Color(0xFF8FA6AE);
  static const Color keypadDark = Color(0xFF1B2E36);
}
