import 'dart:async';
import 'package:flutter/foundation.dart';
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

  /// The user tapped «تماس در جریان» in the shade and wants the call screen
  /// back. Carries nothing; it is a request, not a state — see
  /// [NativeCallService.onShowCallUi], which is what `CallUiCoordinator`
  /// listens to (the bloc has nothing to change).
  showCallUi,

  /// An event name this build does not know. Explicitly a no-op: it used to
  /// fall through to [disconnected], which reads as «the call ended» and tears
  /// a live call's screen down over a payload nobody understood.
  unknown,
}

/// Where the call's audio is coming out.
///
/// A boolean «speaker on/off» cannot express a bluetooth headset, which is why
/// «بلوتوث» in the output picker used to be a hardcoded «دستگاه بلوتوثی یافت
/// نشد» that did nothing whatever was connected.
enum CallAudioRoute {
  earpiece,
  speaker,
  bluetooth,
  wired;

  static CallAudioRoute parse(String? name) => switch (name) {
    'speaker' => CallAudioRoute.speaker,
    'bluetooth' => CallAudioRoute.bluetooth,
    'wired' => CallAudioRoute.wired,
    _ => CallAudioRoute.earpiece,
  };

  String get wireName => name;
}

/// Why a call ended, as telecom reports it (`android.telecom.DisconnectCause`
/// codes, named in `CallInCallService.causeName`).
enum CallDisconnectCause {
  /// The far end was engaged.
  busy,

  /// The far end (or the network on its behalf) ended it — for a call that
  /// never connected, that is «برنداشتن».
  remote,

  /// This phone hung up.
  local,

  /// This phone gave up before the call was placed.
  canceled,
  missed,
  rejected,

  /// The network could not complete it (no service, congestion…).
  error,

  /// Barred — retrying cannot help.
  restricted,
  other,
  answeredElsewhere,
  callPulled,
  unknown;

  static CallDisconnectCause parse(String? name) => switch (name) {
    'busy' => CallDisconnectCause.busy,
    'remote' => CallDisconnectCause.remote,
    'local' => CallDisconnectCause.local,
    'canceled' => CallDisconnectCause.canceled,
    'missed' => CallDisconnectCause.missed,
    'rejected' => CallDisconnectCause.rejected,
    'error' => CallDisconnectCause.error,
    'restricted' => CallDisconnectCause.restricted,
    'other' => CallDisconnectCause.other,
    'answered_elsewhere' => CallDisconnectCause.answeredElsewhere,
    'call_pulled' => CallDisconnectCause.callPulled,
    _ => CallDisconnectCause.unknown,
  };

  /// Whether an outgoing call that ended this way, without ever connecting,
  /// is worth dialling again.
  ///
  /// Busy and "the far end dropped it before answering" are the two the
  /// feature exists for; a network error is included because «شبکه در دسترس
  /// نیست» is exactly when a person keeps pressing redial by hand. Everything
  /// this phone did itself (hung up, cancelled) and everything a retry cannot
  /// change (barred, answered on another device) is out.
  bool get isRetryable => switch (this) {
    busy || remote || error || other => true,
    _ => false,
  };
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

  /// The live output, and which outputs telecom says exist. `hasBluetooth` is
  /// what tells a usable «بلوتوث» row from one that would do nothing.
  final CallAudioRoute? route;
  final bool? hasBluetooth;
  final bool? hasWiredHeadset;
  final String? bluetoothName;

  /// Only meaningful for [NativeCallEvent.callsChanged].
  final int? callCount;
  final bool? canMerge;

  /// True when the call is a merged conference host (تماس گروهی).
  final bool? isConference;

  /// SIM the call is on, resolved natively from telecom's PhoneAccount. Null
  /// for a VoIP call, an unreadable roster, or a single-SIM phone — all of
  /// which mean "say nothing", never "SIM 1".
  final int? subscriptionId;

  /// When telecom says the call connected. Null until it does.
  ///
  /// The call duration is derived from this rather than counted by the call
  /// screen, because the screen is no longer the only place a call lives: it
  /// can be minimized and re-opened, and a screen-local counter restarted at
  /// zero every time — as it also did on a cold start into a call that had
  /// already been running for minutes.
  final DateTime? connectedAt;

  /// Why the call ended — only meaningful for [NativeCallEvent.disconnected].
  ///
  /// This is what «تماس مجدد خودکار» is decided on, together with
  /// [connectedAt]: an outgoing call that ended [CallDisconnectCause.busy] or
  /// was dropped by the far end before it ever connected is a failed attempt;
  /// one the user hung up on ([CallDisconnectCause.local]) is not.
  /// [disconnectReason] is the carrier's own wording, kept for the log only.
  final CallDisconnectCause disconnectCause;
  final String? disconnectReason;

  const CallInfo({
    required this.event,
    this.phone = '',
    this.name,
    this.direction = 'outgoing',
    this.speaker,
    this.muted,
    this.route,
    this.hasBluetooth,
    this.hasWiredHeadset,
    this.bluetoothName,
    this.callCount,
    this.canMerge,
    this.isConference,
    this.subscriptionId,
    this.connectedAt,
    this.disconnectCause = CallDisconnectCause.unknown,
    this.disconnectReason,
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

  /// Fires when the shade's «تماس در جریان» card is tapped: put the call
  /// screen back.
  ///
  /// A stream of its own rather than a bloc state, because nothing about the
  /// *call* changed — only what should be on screen — and `CallUiCoordinator`
  /// is the one thing that decides that.
  static final StreamController<void> _showCallUiController =
      StreamController<void>.broadcast();

  static Stream<void> get onShowCallUi => _showCallUiController.stream;

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
        'show_call_ui' => NativeCallEvent.showCallUi,
        _ => NativeCallEvent.unknown,
      };

      if (event == NativeCallEvent.showCallUi) _showCallUiController.add(null);

      return CallInfo(
        event: event,
        phone: map['phone'] as String? ?? '',
        name: map['name'] as String?,
        direction: map['direction'] as String? ?? 'outgoing',
        speaker: map['speaker'] as bool?,
        muted: map['muted'] as bool?,
        route: map.containsKey('route')
            ? CallAudioRoute.parse(map['route'] as String?)
            : null,
        hasBluetooth: map['hasBluetooth'] as bool?,
        hasWiredHeadset: map['hasWiredHeadset'] as bool?,
        bluetoothName: map['bluetoothName'] as String?,
        callCount: map['count'] as int?,
        canMerge: map['canMerge'] as bool?,
        isConference: map['isConference'] as bool?,
        subscriptionId: switch (map['subscriptionId']) {
          final int id when id >= 0 => id,
          _ => null,
        },
        // 0 = telecom has no connect time yet (still dialing/ringing).
        connectedAt: switch (map['connectTimeMillis']) {
          final int ms when ms > 0 => DateTime.fromMillisecondsSinceEpoch(ms),
          _ => null,
        },
        disconnectCause: CallDisconnectCause.parse(map['cause'] as String?),
        disconnectReason: map['reason'] as String?,
      );
    });
    return _stream!;
  }

  /// Tells the native side whether the in-call route is on screen.
  ///
  /// This is what posts and cancels the shade's «تماس در جریان» card: leaving
  /// the call screen for another screen of the *same app* produces no Android
  /// lifecycle callback, so nothing native can notice it.
  ///
  /// Fire-and-forget and never allowed to throw: a channel that is not up yet
  /// (or an OEM that refused the notification) must not break minimizing.
  Future<void> setCallScreenVisible({required bool visible}) async {
    try {
      await _method.invokeMethod('setCallScreenVisible', {'visible': visible});
    } catch (e) {
      debugPrint('NativeCallService.setCallScreenVisible failed: $e');
    }
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

  /// Routes the call's audio explicitly. The only way to reach a bluetooth
  /// headset — [setSpeakerphone] can only pick between the two built-in
  /// outputs.
  Future<void> setAudioRoute(CallAudioRoute route) =>
      _method.invokeMethod('setAudioRoute', {'route': route.wireName});

  /// The live audio state, for a call screen that mounted before any
  /// AUDIO_STATE event arrived (cold start into an ongoing call). Null when no
  /// call is bound.
  Future<CallInfo?> getAudioState() async {
    try {
      final raw = await _method.invokeMethod<Map<Object?, Object?>>(
        'getAudioState',
      );
      if (raw == null) return null;
      final map = Map<String, dynamic>.from(raw);
      return CallInfo(
        event: NativeCallEvent.audioState,
        speaker: map['speaker'] as bool?,
        muted: map['muted'] as bool?,
        route: CallAudioRoute.parse(map['route'] as String?),
        hasBluetooth: map['hasBluetooth'] as bool?,
        hasWiredHeadset: map['hasWiredHeadset'] as bool?,
        bluetoothName: map['bluetoothName'] as String?,
      );
    } catch (_) {
      return null;
    }
  }

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

  /// The voicemail number of [subscriptionId] (the system default when null),
  /// or null when the carrier never provisioned one.
  ///
  /// Per SIM because the two cards are two carriers with two mailboxes.
  /// Callers must handle null rather than dialing a guess.
  Future<String?> getVoicemailNumber({int? subscriptionId}) async {
    try {
      return await _method.invokeMethod<String>('getVoicemailNumber', {
        'subscriptionId': subscriptionId ?? -1,
      });
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

  /// Opens the phone's «Sound & vibration» settings.
  ///
  /// The call ringtone and the vibrate-on-ring behaviour belong to Telecom —
  /// this app holds the dialer role but never plays the ringer — so the
  /// settings page links there instead of offering a switch it could not honour.
  Future<void> openSoundSettings() async {
    try {
      await _method.invokeMethod('openSoundSettings');
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

  /// Mirrors «مسدود کردن تماس‌های ناشناس» into a native preference file.
  ///
  /// The rule is applied in `CallInCallService.onCallAdded`, which runs before
  /// — and usually without — a Flutter engine, so the value cannot be read from
  /// this side when it matters. `SettingsBloc` pushes it on load and on every
  /// change, so the mirror can be stale for at most one launch.
  Future<void> setBlockUnknownCallers(bool value) async {
    try {
      await _method.invokeMethod('setBlockUnknownCallers', {'value': value});
    } catch (e) {
      debugPrint('setBlockUnknownCallers failed: $e');
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
