import 'dart:async';
import 'package:flutter/services.dart';

/// رویدادهای چرخه‌حیات تماس — دریافتی از CallEventStreamHandler.kt
enum NativeCallEvent {
  incoming,
  ringing,
  active,
  onHold,
  disconnected,
  callFailed,
}

/// اطلاعات یک رویداد تماس
class CallInfo {
  final NativeCallEvent event;
  final String phone;
  final String direction; // 'incoming' | 'outgoing'

  const CallInfo({
    required this.event,
    this.phone = '',
    this.direction = 'outgoing',
  });
}

/// Singleton wrapper برای MethodChannel و EventChannel تماس
class NativeCallService {
  NativeCallService._();
  static final NativeCallService instance = NativeCallService._();

  static const _method = MethodChannel(
    'com.example.communication_super_app/call',
  );
  static const _events = EventChannel(
    'com.example.communication_super_app/call_events',
  );

  Stream<CallInfo>? _stream;

  /// Stream رویدادهای تماس — یک‌بار ساخته می‌شود و reuse می‌شود
  Stream<CallInfo> get callEvents {
    _stream ??= _events.receiveBroadcastStream().map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      final eventName = (map['event'] as String).toLowerCase();

      final event = switch (eventName) {
        'incoming' => NativeCallEvent.incoming,
        'ringing' => NativeCallEvent.ringing,
        'active' => NativeCallEvent.active,
        'on_hold' => NativeCallEvent.onHold,
        'disconnected' => NativeCallEvent.disconnected,
        'call_failed' => NativeCallEvent.callFailed,
        _ => NativeCallEvent.disconnected,
      };

      return CallInfo(
        event: event,
        phone: map['phone'] as String? ?? '',
        direction: map['direction'] as String? ?? 'outgoing',
      );
    });
    return _stream!;
  }

  Future<void> makeCall(String phone) =>
      _method.invokeMethod('makeCall', {'phone': phone});

  Future<void> endCall() => _method.invokeMethod('endCall');

  Future<void> answerCall() => _method.invokeMethod('answerCall');

  Future<void> rejectCall() => _method.invokeMethod('rejectCall');

  Future<void> holdCall({bool hold = true}) =>
      _method.invokeMethod('holdCall', {'hold': hold});

  Future<void> muteCall({required bool muted}) =>
      _method.invokeMethod('muteCall', {'muted': muted});

  Future<void> setSpeakerphone({required bool on}) =>
      _method.invokeMethod('setSpeakerphone', {'on': on});

  Future<void> sendDtmf(String digit) =>
      _method.invokeMethod('sendDtmf', {'digit': digit});

  Future<bool> isInCall() async =>
      await _method.invokeMethod<bool>('isInCall') ?? false;
}
