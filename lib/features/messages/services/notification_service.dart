import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:flutter/material.dart';

class NotificationService {
  static final NotificationService _instance = NotificationService._internal();
  factory NotificationService() => _instance;
  NotificationService._internal();

  final FlutterLocalNotificationsPlugin _notifications = FlutterLocalNotificationsPlugin();
  bool _initialized = false;
  
  // Callback to handle notification taps (will be set by main app)
  Function(String threadId)? onNotificationTapped;

  Future<void> initialize() async {
    if (_initialized) return;

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings(
      requestAlertPermission: true,
      requestBadgePermission: true,
      requestSoundPermission: true,
    );

    const initSettings = InitializationSettings(
      android: androidSettings,
      iOS: iosSettings,
    );

    await _notifications.initialize(
      initSettings,
      onDidReceiveNotificationResponse: _onNotificationTapped,
    );

    // Create notification channel for Android
    const androidChannel = AndroidNotificationChannel(
      'sms_channel',
      'پیام‌های کوتاه',
      description: 'اعلان‌های پیام‌های کوتاه دریافتی',
      importance: Importance.high,
      enableVibration: true,
      playSound: true,
    );

    await _notifications
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.createNotificationChannel(androidChannel);

    _initialized = true;
  }

  Future<void> showSmsNotification({
    required String contactName,
    required String phoneNumber,
    required String message,
    required String threadId,
  }) async {
    if (!_initialized) await initialize();

    final displayName = contactName.isNotEmpty ? contactName : phoneNumber;

    const androidDetails = AndroidNotificationDetails(
      'sms_channel',
      'پیام‌های کوتاه',
      channelDescription: 'اعلان‌های پیام‌های کوتاه دریافتی',
      importance: Importance.high,
      priority: Priority.high,
      showWhen: true,
      enableVibration: true,
      playSound: true,
      icon: '@mipmap/ic_launcher',
    );

    const iosDetails = DarwinNotificationDetails(
      presentAlert: true,
      presentBadge: true,
      presentSound: true,
    );

    const notificationDetails = NotificationDetails(
      android: androidDetails,
      iOS: iosDetails,
    );

    await _notifications.show(
      threadId.hashCode, // Use thread ID hash as notification ID
      displayName,
      message,
      notificationDetails,
      payload: threadId, // Store thread ID to open conversation
    );
  }

  void _onNotificationTapped(NotificationResponse response) {
    final threadId = response.payload;
    if (threadId != null) {
      // Call the callback if registered
      onNotificationTapped?.call(threadId);
      debugPrint('Notification tapped for thread: $threadId');
    }
  }

  Future<void> cancelAll() async {
    await _notifications.cancelAll();
  }

  Future<void> cancel(int id) async {
    await _notifications.cancel(id);
  }
}

