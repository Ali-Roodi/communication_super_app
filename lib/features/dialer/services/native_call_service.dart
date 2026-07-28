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

  /// Telecom audio route/mute changed (e.g. bluetooth connected) — carries
  /// [CallInfo.speaker] / [CallInfo.muted] so the UI toggles stay honest.
  audioState,

  /// Number of concurrent calls changed — carries [CallInfo.callCount] /
  /// [CallInfo.canMerge] (add-call / merge-to-conference UI).
  callsChanged,
}

/// اطلاعات یک رویداد تماس
class CallInfo {
  final NativeCallEvent event;
  final String phone;

  /// Caller name, resolved natively (ContactsContract PhoneLookup) so the call
  /// screen never has to render the bare number first.
  final String? name;
  final String direction; // 'incoming' | 'outgoing'

  /// Only meaningful for [NativeCallEvent.audioState].
  final bool? speaker;
  final bool? muted;

  /// Only meaningful for [NativeCallEvent.callsChanged].
  final int? callCount;
  final bool? canMerge;

  /// True when the call is a merged conference host (تماس گروهی).
  final bool? isConference;

  const CallInfo({
    required this.event,
    this.phone = '',
    this.name,
    this.direction = 'outgoing',
    this.speaker,
    this.muted,
    this.callCount,
    this.canMerge,
    this.isConference,
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
        'audio_state' => NativeCallEvent.audioState,
        'calls_changed' => NativeCallEvent.callsChanged,
        _ => NativeCallEvent.disconnected,
      };

      return CallInfo(
        event: event,
        phone: map['phone'] as String? ?? '',
        name: map['name'] as String?,
        direction: map['direction'] as String? ?? 'outgoing',
        speaker: map['speaker'] as bool?,
        muted: map['muted'] as bool?,
        callCount: map['count'] as int?,
        canMerge: map['canMerge'] as bool?,
        isConference: map['isConference'] as bool?,
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

  /// Merges the active and held calls into a conference (تماس گروهی).
  Future<void> mergeCalls() => _method.invokeMethod('mergeCalls');

  /// Swaps the active and held calls.
  Future<void> swapCalls() => _method.invokeMethod('swapCalls');

  Future<bool> isInCall() async =>
      await _method.invokeMethod<bool>('isInCall') ?? false;

  // ── Default dialer role ────────────────────────────────────

  /// True when this app currently holds the default-dialer role.
  Future<bool> isDefaultDialer() async =>
      await _method.invokeMethod<bool>('isDefaultDialer') ?? false;

  /// Shows the system "set default phone app" dialog.
  /// Resolves to true when granted.
  Future<bool> requestDefaultDialerRole() async {
    try {
      return await _method.invokeMethod<bool>('requestDefaultDialerRole') ??
          false;
    } catch (_) {
      return false;
    }
  }

  // ── Misc system hooks ──────────────────────────────────────

  /// The SIM's voicemail number, or null when the carrier never provisioned
  /// one. Callers must handle null rather than dialing a guess.
  Future<String?> getVoicemailNumber() async {
    try {
      return await _method.invokeMethod<String>('getVoicemailNumber');
    } catch (_) {
      return null;
    }
  }

  /// Opens this app's system notification settings.
  Future<void> openNotificationSettings() async {
    try {
      await _method.invokeMethod('openNotificationSettings');
    } catch (_) {
      // A device with no such settings activity: nothing to do.
    }
  }

  /// Whether an incoming call may open the app's own call screen. False on
  /// Android 14+ until the user grants it — the app took the dialer role after
  /// install, so the permission is not auto-granted and a call on a locked
  /// phone shows the OEM dialer instead.
  Future<bool> canUseFullScreenIntent() async =>
      await _method.invokeMethod<bool>('canUseFullScreenIntent') ?? true;

  /// Opens the per-app settings screen where that is granted.
  Future<void> openFullScreenIntentSettings() async {
    try {
      await _method.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {
      // Older Android: nothing to grant.
    }
  }
}
