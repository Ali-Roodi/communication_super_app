import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../contacts/models/contact_model.dart';
import '../services/native_call_service.dart';
import 'dialer_event.dart';
import 'dialer_state.dart';

class DialerBloc extends Bloc<DialerEvent, DialerState> {
  final ContactRepository _contactRepository;
  final NativeCallService _callService;

  Timer? _debounceTimer;
  List<ContactModel> _allContacts = [];
  StreamSubscription<CallInfo>? _callSub;

  DialerBloc(
    this._contactRepository, {
    NativeCallService? callService,
  })  : _callService = callService ?? NativeCallService.instance,
        super(const DialerState()) {
    // ── Keypad handlers ─────────────────────────────────────
    on<DialerLoadContacts>(_onLoadContacts);
    on<DialerNumberPressed>(_onNumberPressed);
    on<DialerNumberCleared>(_onNumberCleared);
    on<DialerNumberDeleted>(_onNumberDeleted);
    on<DialerFilterContacts>(_onFilterContacts);

    // ── Call handlers (Step 3) ───────────────────────────────
    on<MakeCall>(_onMakeCall);
    on<EndCall>(_onEndCall);
    on<AnswerCall>(_onAnswer);
    on<RejectCall>(_onReject);
    on<ToggleMute>(_onToggleMute);
    on<ToggleSpeaker>(_onToggleSpeaker);
    on<HoldCall>(_onHold);
    on<SendDtmf>(_onSendDtmf);
    on<CallEventReceived>(_onCallEvent);

    add(const DialerLoadContacts());
    _listenCallEvents();
  }

  // ── Call event stream ──────────────────────────────────────

  void _listenCallEvents() {
    _callSub = _callService.callEvents.listen(
      (info) => add(CallEventReceived(info)),
      onError: (e) => debugPrint('DialerBloc: callEvents error: $e'),
    );
  }

  // ── Keypad handlers ────────────────────────────────────────

  Future<void> _onLoadContacts(
    DialerLoadContacts event,
    Emitter<DialerState> emit,
  ) async {
    emit(state.copyWith(isLoadingContacts: true));
    try {
      _allContacts = await _contactRepository.getAllContacts();
      emit(state.copyWith(isLoadingContacts: false));
    } catch (e) {
      emit(state.copyWith(isLoadingContacts: false, error: e.toString()));
    }
  }

  void _onNumberPressed(
    DialerNumberPressed event,
    Emitter<DialerState> emit,
  ) {
    final newNumber = state.dialedNumber + event.number;
    _debounceTimer?.cancel();
    emit(state.copyWith(
      dialedNumber: newNumber,
      isLoadingContacts: true,
      clearError: true,
    ));
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      add(DialerFilterContacts(newNumber));
    });
  }

  void _onNumberCleared(
    DialerNumberCleared event,
    Emitter<DialerState> emit,
  ) {
    _debounceTimer?.cancel();
    emit(state.copyWith(
      dialedNumber: '',
      matchingContacts: [],
      isNumberInContacts: false,
      isLoadingContacts: false,
      clearError: true,
    ));
  }

  void _onNumberDeleted(
    DialerNumberDeleted event,
    Emitter<DialerState> emit,
  ) {
    if (state.dialedNumber.isEmpty) return;
    final newNumber = state.dialedNumber
        .substring(0, state.dialedNumber.length - 1);
    _debounceTimer?.cancel();

    if (newNumber.isEmpty) {
      emit(state.copyWith(
        dialedNumber: '',
        matchingContacts: [],
        isNumberInContacts: false,
        isLoadingContacts: false,
      ));
    } else {
      emit(state.copyWith(dialedNumber: newNumber, isLoadingContacts: true));
      _debounceTimer = Timer(const Duration(milliseconds: 300), () {
        add(DialerFilterContacts(newNumber));
      });
    }
  }

  Future<void> _onFilterContacts(
    DialerFilterContacts event,
    Emitter<DialerState> emit,
  ) async {
    if (event.query.isEmpty) {
      emit(state.copyWith(
        matchingContacts: [],
        isNumberInContacts: false,
        isLoadingContacts: false,
      ));
      return;
    }
    try {
      final matches = _contactRepository.filterContactsByPhoneDigits(
        _allContacts,
        event.query,
      );
      final inContacts = matches.any(
        (c) => c.phoneNumbers.any(
          (p) => _digitsOnly(p) == _digitsOnly(event.query),
        ),
      );
      emit(state.copyWith(
        matchingContacts: matches,
        isNumberInContacts: inContacts,
        isLoadingContacts: false,
      ));
    } catch (e) {
      emit(state.copyWith(isLoadingContacts: false, error: e.toString()));
    }
  }

  // ── Call handlers ──────────────────────────────────────────

  Future<void> _onMakeCall(MakeCall event, Emitter<DialerState> emit) async {
    if (state.dialedNumber.isEmpty) return;
    emit(state.copyWith(callStatus: CallStatus.connecting, clearError: true));
    try {
      await _callService.makeCall(state.dialedNumber);
    } catch (e) {
      emit(state.copyWith(
        callStatus: CallStatus.idle,
        error: e.toString(),
      ));
    }
  }

  void _onCallEvent(CallEventReceived event, Emitter<DialerState> emit) {
    final info = event.callInfo;
    switch (info.event) {
      case NativeCallEvent.incoming:
        emit(state.copyWith(
          callStatus: CallStatus.incoming,
          activePhone: info.phone,
        ));
      case NativeCallEvent.ringing:
        emit(state.copyWith(callStatus: CallStatus.ringing));
      case NativeCallEvent.active:
        emit(state.copyWith(callStatus: CallStatus.active));
      case NativeCallEvent.onHold:
        emit(state.copyWith(callStatus: CallStatus.onHold));
      case NativeCallEvent.disconnected:
        // reset call state — keypad و dialedNumber را حفظ کن
        emit(state.copyWith(
          callStatus: CallStatus.idle,
          activePhone: '',
          isMuted: false,
          isSpeakerOn: false,
          clearError: true,
        ));
      case NativeCallEvent.callFailed:
        emit(state.copyWith(
          callStatus: CallStatus.idle,
          error: 'تماس برقرار نشد',
        ));
    }
  }

  Future<void> _onToggleMute(
      ToggleMute event, Emitter<DialerState> emit) async {
    final muted = !state.isMuted;
    await _callService.muteCall(muted: muted);
    emit(state.copyWith(isMuted: muted));
  }

  Future<void> _onToggleSpeaker(
      ToggleSpeaker event, Emitter<DialerState> emit) async {
    final on = !state.isSpeakerOn;
    await _callService.setSpeakerphone(on: on);
    emit(state.copyWith(isSpeakerOn: on));
  }

  Future<void> _onEndCall(EndCall event, Emitter<DialerState> emit) async {
    try {
      await _callService.endCall();
    } catch (e) {
      debugPrint('DialerBloc: endCall error: $e');
    }
  }

  Future<void> _onAnswer(AnswerCall event, Emitter<DialerState> emit) async {
    try {
      await _callService.answerCall();
    } catch (e) {
      debugPrint('DialerBloc: answerCall error: $e');
    }
  }

  Future<void> _onReject(RejectCall event, Emitter<DialerState> emit) async {
    try {
      await _callService.rejectCall();
    } catch (e) {
      debugPrint('DialerBloc: rejectCall error: $e');
    }
  }

  Future<void> _onHold(HoldCall event, Emitter<DialerState> emit) async {
    try {
      await _callService.holdCall(hold: event.hold);
    } catch (e) {
      debugPrint('DialerBloc: holdCall error: $e');
    }
  }

  Future<void> _onSendDtmf(SendDtmf event, Emitter<DialerState> emit) async {
    try {
      await _callService.sendDtmf(event.digit);
    } catch (e) {
      debugPrint('DialerBloc: sendDtmf error: $e');
    }
  }

  // ── Helpers ───────────────────────────────────────────────

  static String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^\d]'), '');

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _callSub?.cancel();
    return super.close();
  }
}
