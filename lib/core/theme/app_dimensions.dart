/// ابعاد طراحی — استخراج‌شده از فایل Figma «قاسم».
///
/// تمام فاصله‌ها، گردی گوشه‌ها و ارتفاع‌ها از این‌جا خوانده می‌شوند تا اپ با
/// طراحی هم‌گام بماند. به‌جای اعداد سخت‌کدشده از این ثابت‌ها استفاده کنید.
abstract class AppDimensions {
  // ── Padding / Spacing ───────────────────────────────────
  static const double paddingXs = 4;
  static const double paddingSm = 8;
  static const double paddingMd = 16; // padding افقی استاندارد صفحه
  static const double paddingLg = 24;
  static const double paddingXl = 32;

  /// فاصله عمودی بین آیتم‌های لیست
  static const double listItemGap = 12;

  // ── Corner Radius ───────────────────────────────────────
  static const double radiusSm = 8;
  static const double radiusMd = 12;
  static const double radiusLg = 16;
  static const double radiusXl = 24;
  static const double radiusPill = 32; // دکمه‌های قرص‌شکل (تماس، کلیدها)

  // ── Elevation / Shadow ──────────────────────────────────
  /// Drop Shadow-Black فایل Figma: rgba(0,0,0,0.05) · blur 15 · spread -5
  static const double shadowBlur = 15;
  static const double shadowSpread = -5;
  static const double shadowOpacity = 0.05;

  // ── Component sizes ─────────────────────────────────────
  static const double avatarSm = 40;
  static const double avatarMd = 48;
  static const double avatarLg = 56;
  static const double avatarXl = 110; // آواتار صفحه جزئیات مخاطب

  static const double iconSm = 16;
  static const double iconMd = 20;
  static const double iconLg = 24;

  /// حداقل ناحیه لمسی (Material a11y)
  static const double minTapTarget = 48;

  /// ارتفاع نوار پایین (Bottom Navigation)
  static const double bottomNavHeight = 64;
}
