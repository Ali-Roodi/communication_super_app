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

  /// SIM the call is on, resolved natively from telecom's PhoneAccount. Null
  /// for a VoIP call, an unreadable roster, or a single-SIM phone — all of
  /// which mean "say nothing", never "SIM 1".
  final int? subscriptionId;

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
    this.subscriptionId,
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
        subscriptionId: switch (map['subscriptionId']) {
          final int id when id >= 0 => id,
          _ => null,
        },
      );
    });
    return _stream!;
  }

  /// Places a call.
  ///
  /// [subscriptionId] names the SIM; null (or an id whose card is gone) means
  /// "let telecom choose", which is what honours the user's system-wide default
  /// voice SIM. Prefer `placeCall` (`core/sim/sim_call.dart`) over calling this
  /// directly — it asks the user when there is a choice to make.
  Future<void> makeCall(String phone, {int? subscriptionId}) =>
      _method.invokeMethod('makeCall', {
        'phone': phone,
        'subscriptionId': subscriptionId ?? -1,
      });

  Future<void> endCall() => _method.invokeMethod('endCall');

  Future<void> answerCall() => _method.invokeMethod('answerCall');

  Future<void> rejectCall() => _method.invokeMethod('rejectCall');

  Future<void> holdCall({bool hold = true}) =>
      _method.invokeMethod('holdCall', {'hold': hold});

  Future<void> muteCall({required bool muted}) =>
      _method.invokeMethod('muteCall', {'muted': muted});

  Future<void> setSpeakerphone({required bool on}) =>
      _method.invokeMethod('setSpeakerphone', {'on': on});

  /// Plays the DTMF tone **and transmits it to the remote party** — the in-call
  /// keypad (IVR menus).
  Future<void> sendDtmf(String digit) =>
      _method.invokeMethod('sendDtmf', {'digit': digit});

  /// Audible keypress feedback ONLY — never transmitted.
  ///
  /// The dialer keypad must use this. It shares the app with a live call
  /// («افزودن تماس» opens the same keypad over one), and [sendDtmf] pushes the
  /// tone into `Call.playDtmfTone` whenever a call exists: typing the number of
  /// the person to add played every digit down the line to the person already
  /// on it.
  Future<void> playKeypadTone(String digit) =>
      _method.invokeMethod('playKeypadTone', {'digit': digit});

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

  /// Whether an incoming call can show anything at all.
  ///
  /// False when notifications are off for the app, or the «تماس ورودی» channel
  /// was muted: the CallStyle card is dropped *and* its full-screen intent
  /// never fires, so a locked phone just rings with no way to answer. Nothing
  /// in the call path can notice this by itself — hence the explicit check.
  Future<bool> areCallNotificationsEnabled() async {
    try {
      return await _method.invokeMethod<bool>('areCallNotificationsEnabled') ??
          true;
    } catch (_) {
      return true;
    }
  }

  /// Opens the per-app settings screen where that is granted.
  Future<void> openFullScreenIntentSettings() async {
    try {
      await _method.invokeMethod('openFullScreenIntentSettings');
    } catch (_) {
      // Older Android: nothing to grant.
    }
  }
}
