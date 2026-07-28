import 'package:equatable/equatable.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';

/// وضعیت چرخه‌حیات تماس
enum CallStatus { idle, connecting, ringing, active, incoming, onHold }

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

  /// تعداد تماس‌های هم‌زمان (بدون فرزندان کنفرانس) و امکان ادغام آن‌ها.
  final int callCount;
  final bool canMerge;

  /// تماس جاری یک کنفرانس ادغام‌شده است (تماس گروهی).
  final bool isConference;
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
    this.callCount = 0,
    this.canMerge = false,
    this.isConference = false,
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
    int? callCount,
    bool? canMerge,
    bool? isConference,
    String? error,
    bool clearError = false,
  }) {
    return DialerState(
      dialedNumber: dialedNumber ?? this.dialedNumber,
      matchingNumbers: matchingNumbers ?? this.matchingNumbers,
      isNumberInContacts: isNumberInContacts ?? this.isNumberInContacts,
      isLoadingContacts: isLoadingContacts ?? this.isLoadingContacts,
      callStatus: callStatus ?? this.callStatus,
      activePhone: activePhone ?? this.activePhone,
      activeName: activeName ?? this.activeName,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      callCount: callCount ?? this.callCount,
      canMerge: canMerge ?? this.canMerge,
      isConference: isConference ?? this.isConference,
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
    callCount,
    canMerge,
    isConference,
    error,
  ];
}
