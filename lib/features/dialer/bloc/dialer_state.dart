import 'package:equatable/equatable.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';

/// وضعیت چرخه‌حیات تماس
enum CallStatus { idle, connecting, ringing, active, incoming, onHold }

/// Single-state class — شامل هم keypad و هم call state
class DialerState extends Equatable {
  // ── Keypad ────────────────────────────────────────────────
  final String dialedNumber;
  final List<ContactModel> matchingContacts;
  final bool isNumberInContacts;
  final bool isLoadingContacts;

  // ── Call ──────────────────────────────────────────────────
  final CallStatus callStatus;
  final String activePhone;
  final bool isMuted;
  final bool isSpeakerOn;

  /// تعداد تماس‌های هم‌زمان (بدون فرزندان کنفرانس) و امکان ادغام آن‌ها.
  final int callCount;
  final bool canMerge;
  final String? error;

  const DialerState({
    this.dialedNumber = '',
    this.matchingContacts = const [],
    this.isNumberInContacts = false,
    this.isLoadingContacts = false,
    this.callStatus = CallStatus.idle,
    this.activePhone = '',
    this.isMuted = false,
    this.isSpeakerOn = false,
    this.callCount = 0,
    this.canMerge = false,
    this.error,
  });

  bool get isInCall =>
      callStatus == CallStatus.active ||
      callStatus == CallStatus.onHold ||
      callStatus == CallStatus.ringing ||
      callStatus == CallStatus.connecting;

  DialerState copyWith({
    String? dialedNumber,
    List<ContactModel>? matchingContacts,
    bool? isNumberInContacts,
    bool? isLoadingContacts,
    CallStatus? callStatus,
    String? activePhone,
    bool? isMuted,
    bool? isSpeakerOn,
    int? callCount,
    bool? canMerge,
    String? error,
    bool clearError = false,
  }) {
    return DialerState(
      dialedNumber: dialedNumber ?? this.dialedNumber,
      matchingContacts: matchingContacts ?? this.matchingContacts,
      isNumberInContacts: isNumberInContacts ?? this.isNumberInContacts,
      isLoadingContacts: isLoadingContacts ?? this.isLoadingContacts,
      callStatus: callStatus ?? this.callStatus,
      activePhone: activePhone ?? this.activePhone,
      isMuted: isMuted ?? this.isMuted,
      isSpeakerOn: isSpeakerOn ?? this.isSpeakerOn,
      callCount: callCount ?? this.callCount,
      canMerge: canMerge ?? this.canMerge,
      error: clearError ? null : (error ?? this.error),
    );
  }

  @override
  List<Object?> get props => [
    dialedNumber,
    matchingContacts,
    isNumberInContacts,
    isLoadingContacts,
    callStatus,
    activePhone,
    isMuted,
    isSpeakerOn,
    callCount,
    canMerge,
    error,
  ];
}
