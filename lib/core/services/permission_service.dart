import 'package:flutter/foundation.dart';
import 'package:permission_handler/permission_handler.dart';

/// Centralized runtime-permission management.
///
/// All runtime permission requests go through this singleton so that:
///  - No two features request the same permission dialog simultaneously.
///  - A single call-site (PermissionGate) can batch all requests before the
///    main navigation is shown, preventing the multi-screen race condition that
///    crashes the app on first run.
class PermissionService {
  PermissionService._();

  static final PermissionService instance = PermissionService._();

  /// The full set of runtime permissions the app needs.
  ///
  /// [Permission.notification] is included for Android 13+ (API 33).
  /// On older Android versions permission_handler auto-grants it, so it is
  /// safe to always include it in the list.
  static List<Permission> get requiredPermissions => [
    Permission.sms,
    Permission.phone,
    Permission.contacts,
    Permission.notification, // B4 fix: required on Android 13+ (API 33+)
  ];

  /// Returns `true` if every required permission is already granted.
  /// Does NOT show any dialog.
  Future<bool> hasAllRequiredPermissions() async {
    for (final p in requiredPermissions) {
      final status = await p.status;
      if (!status.isGranted) return false;
    }
    return true;
  }

  /// Requests every required permission in sequence (one dialog at a time).
  /// Returns the final [PermissionStatus] for each.
  Future<Map<Permission, PermissionStatus>> requestAllPermissions() async {
    final results = <Permission, PermissionStatus>{};
    for (final p in requiredPermissions) {
      try {
        results[p] = await p.request();
        debugPrint('PermissionService: ${p.toString()} → ${results[p]}');
      } catch (e) {
        debugPrint('PermissionService: error requesting $p: $e');
        results[p] = PermissionStatus.denied;
      }
    }
    return results;
  }

  /// Returns `true` if all entries in [results] were granted.
  bool allGranted(Map<Permission, PermissionStatus> results) =>
      results.values.every((s) => s.isGranted);

  /// Human-readable Persian label for each permission.
  static String labelFor(Permission permission) {
    if (permission == Permission.sms) return 'پیامک (خواندن و ارسال)';
    if (permission == Permission.phone) return 'تلفن (شناسه خط)';
    if (permission == Permission.contacts) return 'مخاطبین (مشاهده فهرست)';
    if (permission == Permission.notification) {
      return 'نوتیفیکیشن (نمایش اعلان‌ها)';
    }
    return permission.toString();
  }
}
