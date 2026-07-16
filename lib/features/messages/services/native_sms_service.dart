import 'dart:async';
import 'package:flutter/services.dart';
import 'package:flutter/foundation.dart';

/// High-performance native SMS service that bridges to Android/iOS native code
///
/// Features:
/// - Asynchronous SMS sending via MethodChannel
/// - Real-time SMS receiving via EventChannel
/// - Multipart SMS support (handled natively)
/// - Dual-SIM support
/// - Background-safe reception
/// - No memory leaks or stale references
class NativeSmsService {
  static const MethodChannel _methodChannel = MethodChannel(
    'com.example.communication_super_app/sms',
  );
  static const EventChannel _eventChannel = EventChannel(
    'com.example.communication_super_app/sms_events',
  );

  StreamSubscription<dynamic>? _smsSubscription;
  final StreamController<SmsReceivedEvent> _smsController =
      StreamController<SmsReceivedEvent>.broadcast();

  // Guard against calling initialize() more than once so that the native
  // EventChannel is never set up with more than one active StreamSubscription.
  // A second subscription would trigger onCancel → onListen on the native side
  // (clearing eventSink momentarily), causing a window where SMS events are
  // silently dropped.
  bool _initialized = false;

  /// Stream of incoming SMS messages
  Stream<SmsReceivedEvent> get onSmsReceived => _smsController.stream;

  /// Initialize the SMS service and start listening for incoming messages.
  /// Safe to call multiple times — subsequent calls are no-ops.
  Future<void> initialize() async {
    if (_initialized) {
      debugPrint('NativeSmsService already initialized, skipping');
      return;
    }
    try {
      // Register the native BroadcastReceiver (idempotent on the Kotlin side).
      await _methodChannel.invokeMethod('registerReceiver');

      // Cancel any leftover subscription before creating a new one (safety net
      // for an unexpected double-init path).
      await _smsSubscription?.cancel();
      _smsSubscription = null;

      // Start listening to incoming SMS via EventChannel
      _smsSubscription = _eventChannel.receiveBroadcastStream().listen(
        (dynamic event) {
          try {
            if (event is Map) {
              final smsEvent = SmsReceivedEvent.fromMap(
                Map<String, dynamic>.from(event),
              );
              _smsController.add(smsEvent);
              debugPrint('SMS received: ${smsEvent.address}');
            }
          } catch (e) {
            debugPrint('Error parsing SMS event: $e');
          }
        },
        onError: (dynamic error) {
          debugPrint('SMS EventChannel error: $error');
        },
        cancelOnError: false,
      );

      _initialized = true;
      debugPrint('NativeSmsService initialized successfully');
    } catch (e) {
      debugPrint('Failed to initialize NativeSmsService: $e');
      rethrow;
    }
  }

  /// Send SMS to a phone number
  ///
  /// [phoneNumber] - recipient phone number
  /// [message] - message body
  /// [subscriptionId] - (optional) SIM card subscription ID for dual-SIM devices
  ///
  /// Returns a [SmsSendResult] with success status and metadata
  ///
  /// Throws [PlatformException] if:
  /// - SMS permission is denied
  /// - No SIM card is available
  /// - Network error occurs
  Future<SmsSendResult> sendSms({
    required String phoneNumber,
    required String message,
    int? subscriptionId,
  }) async {
    try {
      if (phoneNumber.trim().isEmpty) {
        throw ArgumentError('Phone number cannot be empty');
      }

      if (message.trim().isEmpty) {
        throw ArgumentError('Message cannot be empty');
      }

      final Map<String, dynamic> params = {
        'phoneNumber': phoneNumber,
        'message': message,
        'subscriptionId': subscriptionId ?? -1,
      };

      final result = await _methodChannel.invokeMethod<Map>('sendSms', params);

      if (result != null) {
        return SmsSendResult.fromMap(Map<String, dynamic>.from(result));
      } else {
        throw PlatformException(
          code: 'SMS_SEND_FAILED',
          message: 'Failed to send SMS - no result from native',
        );
      }
    } on PlatformException catch (e) {
      debugPrint('PlatformException sending SMS: ${e.code} - ${e.message}');
      rethrow;
    } catch (e) {
      debugPrint('Error sending SMS: $e');
      rethrow;
    }
  }

  /// Get available SIM subscriptions (for dual-SIM devices)
  ///
  /// Returns a list of [SimSubscription] objects
  /// Returns empty list if:
  /// - Device doesn't support dual-SIM
  /// - Permission is denied
  /// - No SIM cards are available
  Future<List<SimSubscription>> getAvailableSubscriptions() async {
    try {
      final result = await _methodChannel.invokeMethod<List>(
        'getAvailableSubscriptions',
      );

      if (result == null) {
        return [];
      }

      return result.map((item) {
        return SimSubscription.fromMap(Map<String, dynamic>.from(item));
      }).toList();
    } on PlatformException catch (e) {
      debugPrint('Error getting subscriptions: ${e.code} - ${e.message}');
      return [];
    } catch (e) {
      debugPrint('Error getting subscriptions: $e');
      return [];
    }
  }

  // ── Default SMS app role ────────────────────────────────────────────────

  /// True when this app currently holds the default-SMS-app role.
  Future<bool> isDefaultSmsApp() async {
    try {
      return await _methodChannel.invokeMethod<bool>('isDefaultSmsApp') ??
          false;
    } catch (e) {
      debugPrint('isDefaultSmsApp failed: $e');
      return false;
    }
  }

  /// Shows the system "set default SMS app" dialog.
  /// Resolves to true when the user granted the role.
  Future<bool> requestDefaultSmsRole() async {
    try {
      return await _methodChannel.invokeMethod<bool>('requestDefaultSmsRole') ??
          false;
    } catch (e) {
      debugPrint('requestDefaultSmsRole failed: $e');
      return false;
    }
  }

  /// Opens Settings → Default apps so the user can pick this app manually —
  /// the fallback when the role dialog is unavailable or was auto-denied
  /// (Android permanently auto-denies a role after two refusals).
  Future<void> openDefaultAppsSettings() async {
    try {
      await _methodChannel.invokeMethod('openDefaultAppsSettings');
    } catch (e) {
      debugPrint('openDefaultAppsSettings failed: $e');
    }
  }

  // ── Device SMS provider deletes (global delete) ─────────────────────────

  /// Deletes individual messages from the device SMS provider. Each spec is
  /// `{deviceId: int?}` or `{body: String, timestamp: int}`.
  /// No-op (returns 0) unless this app is the default SMS app.
  Future<int> deleteSmsFromProvider(List<Map<String, Object?>> specs) async {
    if (specs.isEmpty) return 0;
    try {
      return await _methodChannel.invokeMethod<int>('deleteSmsFromProvider', {
            'messages': specs,
          }) ??
          0;
    } catch (e) {
      debugPrint('deleteSmsFromProvider failed: $e');
      return 0;
    }
  }

  /// Deletes a whole conversation (every provider row for [address]).
  /// No-op (returns 0) unless this app is the default SMS app.
  Future<int> deleteSmsThreadFromProvider(String address) async {
    try {
      return await _methodChannel.invokeMethod<int>(
            'deleteSmsThreadFromProvider',
            {'address': address},
          ) ??
          0;
    } catch (e) {
      debugPrint('deleteSmsThreadFromProvider failed: $e');
      return 0;
    }
  }

  /// Clean up resources and cancel subscriptions
  void dispose() {
    _smsSubscription?.cancel();
    _smsSubscription = null;
    if (!_smsController.isClosed) {
      _smsController.close();
    }
    _initialized = false;
    debugPrint('NativeSmsService disposed');
  }
}

/// Event emitted when an SMS is received
class SmsReceivedEvent {
  final String address;
  final String body;
  final int timestamp;
  final int subscriptionId;

  SmsReceivedEvent({
    required this.address,
    required this.body,
    required this.timestamp,
    required this.subscriptionId,
  });

  factory SmsReceivedEvent.fromMap(Map<String, dynamic> map) {
    return SmsReceivedEvent(
      address: map['address'] as String? ?? '',
      body: map['body'] as String? ?? '',
      timestamp:
          map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      subscriptionId: map['subscriptionId'] as int? ?? -1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'address': address,
      'body': body,
      'timestamp': timestamp,
      'subscriptionId': subscriptionId,
    };
  }

  @override
  String toString() {
    return 'SmsReceivedEvent(address: $address, body: ${body.substring(0, body.length > 20 ? 20 : body.length)}..., timestamp: $timestamp, subscriptionId: $subscriptionId)';
  }
}

/// Result of SMS send operation
class SmsSendResult {
  final bool success;
  final String phoneNumber;
  final int messageLength;
  final int parts;
  final int subscriptionId;
  final int timestamp;

  /// Provider row id when the message was written through to the device SMS
  /// store (only while this app is the default SMS app); -1 otherwise.
  final int deviceId;

  SmsSendResult({
    required this.success,
    required this.phoneNumber,
    required this.messageLength,
    required this.parts,
    required this.subscriptionId,
    required this.timestamp,
    this.deviceId = -1,
  });

  factory SmsSendResult.fromMap(Map<String, dynamic> map) {
    return SmsSendResult(
      success: map['success'] as bool? ?? false,
      phoneNumber: map['phoneNumber'] as String? ?? '',
      messageLength: map['messageLength'] as int? ?? 0,
      parts: map['parts'] as int? ?? 1,
      subscriptionId: map['subscriptionId'] as int? ?? -1,
      timestamp:
          map['timestamp'] as int? ?? DateTime.now().millisecondsSinceEpoch,
      deviceId: (map['deviceId'] as num?)?.toInt() ?? -1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'success': success,
      'phoneNumber': phoneNumber,
      'messageLength': messageLength,
      'parts': parts,
      'subscriptionId': subscriptionId,
      'timestamp': timestamp,
    };
  }

  @override
  String toString() {
    return 'SmsSendResult(success: $success, phoneNumber: $phoneNumber, parts: $parts, subscriptionId: $subscriptionId)';
  }
}

/// SIM card subscription information (for dual-SIM devices)
class SimSubscription {
  final int subscriptionId;
  final String displayName;
  final String carrierName;
  final int slotIndex;

  SimSubscription({
    required this.subscriptionId,
    required this.displayName,
    required this.carrierName,
    required this.slotIndex,
  });

  factory SimSubscription.fromMap(Map<String, dynamic> map) {
    return SimSubscription(
      subscriptionId: map['subscriptionId'] as int? ?? -1,
      displayName: map['displayName'] as String? ?? '',
      carrierName: map['carrierName'] as String? ?? '',
      slotIndex: map['slotIndex'] as int? ?? -1,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'subscriptionId': subscriptionId,
      'displayName': displayName,
      'carrierName': carrierName,
      'slotIndex': slotIndex,
    };
  }

  @override
  String toString() {
    return 'SimSubscription(id: $subscriptionId, name: $displayName, carrier: $carrierName, slot: $slotIndex)';
  }
}
