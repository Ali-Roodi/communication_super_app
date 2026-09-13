import 'package:equatable/equatable.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

/// وضعیت چرخه‌حیات تماس
enum CallStatus { idle, connecting, ringing, active, incoming, onHold }

/// «تماس مجدد خودکار» in progress: the number a failed outgoing call is going
/// to be dialled again, and where in the series we are.
///
/// Lives on [DialerState] beside — not inside — [CallStatus]: while it counts
/// down there is **no call** on the phone (`callStatus` is idle) and every
/// teardown path may run; the series has to survive them all, which it does
/// by never being touched by `copyWith` unless named.
class AutoRedial extends Equatable {
  /// Exactly the handle telecom reported for the failed call, redialled as is.
  final String phone;

  /// The SIM the failed call went out on, so the retry does not re-ask.
  final int? subscriptionId;

  /// 1-based: the attempt about to be made (or being made).
  final int attempt;

  /// «تعداد تلاش‌ها» as it was when the series started — a setting changed
  /// mid-series does not stretch or cut it.
  final int maxAttempts;

  /// When the next attempt fires. Null once it has been placed and telecom is
  /// yet to answer (the ended-call screen reads «در حال تماس مجدد…» then).
  final DateTime? dueAt;

  const AutoRedial({
    required this.phone,
    required this.subscriptionId,
    required this.attempt,
    required this.maxAttempts,
    required this.dueAt,
  });

  bool get isCountingDown => dueAt != null;

  AutoRedial placed() => AutoRedial(
    phone: phone,
    subscriptionId: subscriptionId,
    attempt: attempt,
    maxAttempts: maxAttempts,
    dueAt: null,
  );

  @override
  List<Object?> get props => [
    phone,
    subscriptionId,
    attempt,
    maxAttempts,
    dueAt,
  ];
}

/// Single-state class — شامل هم keypad و هم call state
class DialerState extends Equatable {
  // ── Keypad ────────────────────────────────────────────────
  final String dialedNumber;

  /// One entry per contact phone number matching [dialedNumber] — a contact
  /// with two matching numbers appears twice, each row showing its own number.
  final List<PhoneMatch> matchingNumbers;
  final bool isNumberInContacts;
  final bool isLoadingContacts;

  // ── Call ──────────────────────────────────────────────────
  final CallStatus callStatus;
  final String activePhone;

  /// Caller name for [activePhone], resolved natively with the call event so
  /// the call screen never renders the bare number first. Null = unsaved.
  final String? activeName;
  final bool isMuted;
  final bool isSpeakerOn;

  /// The live audio output and what telecom says is available.
  ///
  /// [isSpeakerOn] stays because the control grid's speaker button is a plain
  /// toggle, but it cannot describe a bluetooth headset — which is why the
  /// output picker needs the route itself.
  final CallAudioRoute audioRoute;
  final bool hasBluetooth;
  final bool hasWiredHeadset;
  final String? bluetoothName;

  /// تعداد تماس‌های هم‌زمان (بدون فرزندان کنفرانس) و امکان ادغام آن‌ها.
  final int callCount;
  final bool canMerge;

  /// تماس جاری یک کنفرانس ادغام‌شده است (تماس گروهی).
  final bool isConference;

  /// SIM the live call is on, published with the call event by telecom. Null =
  /// nothing to show (single-SIM phone, VoIP call, unreadable roster).
  final int? activeSubscriptionId;

  /// When telecom says the live call connected. Null while it is still dialing
  /// or ringing, and after it ends.
  ///
  /// The call duration is derived from this, not counted by the call screen:
  /// that screen can now be minimized and re-opened, and a screen-local
  /// counter restarted at zero every time — as it also did on a cold start
  /// into a call that had already been running for minutes.
  final DateTime? callConnectedAt;

  /// A redial series in progress, or null. See [AutoRedial].
  final AutoRedial? autoRedial;

  final String? error;

  const DialerState({
    this.dialedNumber = '',
    this.matchingNumbers = const [],
    this.isNumberInContacts = false,
    this.isLoadingContacts = false,
    this.callStatus = CallStatus.idle,
    this.activePhone = '',
    this.activeName,
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.audioRoute = CallAudioRoute.earpiece,
    this.hasBluetooth = false,
    this.hasWiredHeadset = false,
    this.bluetoothName,
    this.callCount = 0,
    this.canMerge = false,
    this.isConference = false,
    this.activeSubscriptionId,
    this.callConnectedAt,
    this.autoRedial,
    this.error,
  });

  bool get isInCall =>
      callStatus == CallStatus.active ||
      callStatus == CallStatus.onHold ||
      callStatus == CallStatus.ringing ||
      callStatus == CallStatus.connecting;

  DialerState copyWith({
    String? dialedNumber,
    List<PhoneMatch>? matchingNumbers,
    bool? isNumberInContacts,
    bool? isLoadingContacts,
    CallStatus? callStatus,
    String? activePhone,
    String? activeName,
    bool? isMuted,
    bool? isSpeakerOn,
    CallAudioRoute? audioRoute,
    bool? hasBluetooth,
    bool? hasWiredHeadset,
    String? bluetoothName,
    int? callCount,
    bool? canMerge,
    bool? isConference,
    int? activeSubscriptionId,
    DateTime? callConnectedAt,
    AutoRedial? autoRedial,
    String? error,
    bool clearError = false,

    /// Ends the redial series — cancelled, exhausted, or the call connected.
    bool clearAutoRedial = false,

    /// Drops the connect time — the call ended. A plain null cannot say this:
    /// every other field treats null as "leave it alone", and a stale connect
    /// time would keep the return-to-call bar counting after the hang-up.
    bool clearCallConnectedAt = false,

    /// Drops the caller name — the number belongs to nobody in the address
    /// book. A plain null cannot say that, and this is not cosmetic: every
    /// other field reads null as "leave it alone", so a call from an unsaved
    /// number (or from one whose contact was just deleted) inherited the
    /// **previous** caller's name and the call screen named the wrong person.
    bool clearActiveName = false,

    /// Drops the SIM the call is on, for the same reason — and the invariant is
    /// already spelled out in the schema: NULL means unknown, never SIM 1. A
    /// wrong SIM badge is worse than none.
    bool clearActiveSubscriptionId = false,
  }) {
    return DialerState(
      dialedNumber: dialedNumber ?? this.dialedNumber,
      matchingNumbers: matchingNumbers ?? this.matchingNumbers,
      isNumberInContacts: isNumberInContacts ?? this.isNumberInContacts,
      isLoadingContacts: isLoadingContacts ?? this.isLoadingContacts,
      callStatus: callStatus ?? this.callStatus,
      activePhone: activePhone ?? this.activePhone,
      activeName: clearActiveName ? null : (activeName ?? this.activeName),
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      audioRoute: audioRoute ?? this.audioRoute,
      hasBluetooth: hasBluetooth ?? this.hasBluetooth,
      hasWiredHeadset: hasWiredHeadset ?? this.hasWiredHeadset,
      bluetoothName: bluetoothName ?? this.bluetoothName,
      callCount: callCount ?? this.callCount,
      canMerge: canMerge ?? this.canMerge,
      isConference: isConference ?? this.isConference,
      activeSubscriptionId: clearActiveSubscriptionId
          ? null
          : (activeSubscriptionId ?? this.activeSubscriptionId),
      callConnectedAt: clearCallConnectedAt
          ? null
          : (callConnectedAt ?? this.callConnectedAt),
      autoRedial: clearAutoRedial ? null : (autoRedial ?? this.autoRedial),
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [
    dialedNumber,
    matchingNumbers,
    isNumberInContacts,
    isLoadingContacts,
    callStatus,
    activePhone,
    activeName,
    isMuted,
    isSpeakerOn,
    audioRoute,
    hasBluetooth,
    hasWiredHeadset,
    bluetoothName,
    callCount,
    canMerge,
    isConference,
    activeSubscriptionId,
    callConnectedAt,
    autoRedial,
    error,
  ];
}
