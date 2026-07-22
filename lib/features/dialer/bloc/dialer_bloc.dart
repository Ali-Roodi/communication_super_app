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

  DialerBloc(this._contactRepository, {NativeCallService? callService})
    : _callService = callService ?? NativeCallService.instance,
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
    on<MergeCalls>(_onMergeCalls);
    on<SwapCalls>(_onSwapCalls);
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

  void _onNumberPressed(DialerNumberPressed event, Emitter<DialerState> emit) {
    final newNumber = state.dialedNumber + event.number;
    _debounceTimer?.cancel();
    emit(
      state.copyWith(
        dialedNumber: newNumber,
        isLoadingContacts: true,
        clearError: true,
      ),
    );
    _debounceTimer = Timer(const Duration(milliseconds: 300), () {
      add(DialerFilterContacts(newNumber));
    });
  }

  void _onNumberCleared(DialerNumberCleared event, Emitter<DialerState> emit) {
    _debounceTimer?.cancel();
    emit(
      state.copyWith(
        dialedNumber: '',
        matchingContacts: [],
        isNumberInContacts: false,
        isLoadingContacts: false,
        clearError: true,
      ),
    );
  }

  void _onNumberDeleted(DialerNumberDeleted event, Emitter<DialerState> emit) {
    if (state.dialedNumber.isEmpty) return;
    final newNumber = state.dialedNumber.substring(
      0,
      state.dialedNumber.length - 1,
    );
    _debounceTimer?.cancel();

    if (newNumber.isEmpty) {
      emit(
        state.copyWith(
          dialedNumber: '',
          matchingContacts: [],
          isNumberInContacts: false,
          isLoadingContacts: false,
        ),
      );
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
      emit(
        state.copyWith(
          matchingContacts: [],
          isNumberInContacts: false,
          isLoadingContacts: false,
        ),
      );
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
      emit(
        state.copyWith(
          matchingContacts: matches,
          isNumberInContacts: inContacts,
          isLoadingContacts: false,
        ),
      );
    } catch (e) {
      emit(state.copyWith(isLoadingContacts: false, error: e.toString()));
    }
  }

  // ── Call handlers ──────────────────────────────────────────

  Future<void> _onMakeCall(MakeCall event, Emitter<DialerState> emit) async {
    if (state.dialedNumber.isEmpty) return;
    try {
      // Option A: native system dialer opens and manages the full call lifecycle.
      // Clear the keypad so the dialer is ready when the user returns.
      await _callService.makeCall(state.dialedNumber);
      emit(
        state.copyWith(
          dialedNumber: '',
          matchingContacts: [],
          isNumberInContacts: false,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void _onCallEvent(CallEventReceived event, Emitter<DialerState> emit) {
    final info = event.callInfo;
    switch (info.event) {
      case NativeCallEvent.incoming:
        emit(
          state.copyWith(
            callStatus: CallStatus.incoming,
            activePhone: info.phone,
          ),
        );
      case NativeCallEvent.ringing:
        // Outgoing dialing — carry the dialed number so the in-call screen
        // has something to display.
        emit(
          state.copyWith(
            callStatus: CallStatus.ringing,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
          ),
        );
      case NativeCallEvent.active:
        emit(
          state.copyWith(
            callStatus: CallStatus.active,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
          ),
        );
      case NativeCallEvent.onHold:
        emit(state.copyWith(callStatus: CallStatus.onHold));
      case NativeCallEvent.disconnected:
        // reset call state — keypad و dialedNumber را حفظ کن
        emit(
          state.copyWith(
            callStatus: CallStatus.idle,
            activePhone: '',
            isMuted: false,
            isSpeakerOn: false,
            callCount: 0,
            canMerge: false,
            clearError: true,
          ),
        );
      case NativeCallEvent.callFailed:
        emit(
          state.copyWith(callStatus: CallStatus.idle, error: 'تماس برقرار نشد'),
        );
      case NativeCallEvent.audioState:
        // Telecom changed the route/mute outside our toggles (e.g. bluetooth).
        emit(
          state.copyWith(
            isSpeakerOn: info.speaker ?? state.isSpeakerOn,
            isMuted: info.muted ?? state.isMuted,
          ),
        );
      case NativeCallEvent.callsChanged:
        emit(
          state.copyWith(
            callCount: info.callCount ?? state.callCount,
            canMerge: info.canMerge ?? state.canMerge,
          ),
        );
    }
  }

  Future<void> _onToggleMute(
    ToggleMute event,
    Emitter<DialerState> emit,
  ) async {
    final muted = !state.isMuted;
    await _callService.muteCall(muted: muted);
    emit(state.copyWith(isMuted: muted));
  }

  Future<void> _onToggleSpeaker(
    ToggleSpeaker event,
    Emitter<DialerState> emit,
  ) async {
    final on = !state.isSpeakerOn;
    await _callService.setSpeakerphone(on: on);
    emit(state.copyWith(isSpeakerOn: on));
  }

  Future<void> _onEndCall(EndCall event, Emitter<DialerState> emit) async {
    // Reset the call UI IMMEDIATELY so the in-call screen dismisses without
    // waiting for the native round-trip. The actual teardown is fired and
    // forgotten; the DISCONNECTED stream event will arrive as a no-op.
    emit(
      state.copyWith(
        callStatus: CallStatus.idle,
        activePhone: '',
        isMuted: false,
        isSpeakerOn: false,
        callCount: 0,
        canMerge: false,
        clearError: true,
      ),
    );
    unawaited(() async {
      try {
        await _callService.endCall();
      } catch (e) {
        debugPrint('DialerBloc: endCall error: $e');
      }
    }());
  }

  Future<void> _onAnswer(AnswerCall event, Emitter<DialerState> emit) async {
    try {
      await _callService.answerCall();
    } catch (e) {
      debugPrint('DialerBloc: answerCall error: $e');
    }
  }

  Future<void> _onReject(RejectCall event, Emitter<DialerState> emit) async {
    // Same pattern as EndCall: dismiss the incoming-call UI immediately, the
    // native teardown is fire-and-forget (DISCONNECTED arrives as a no-op).
    emit(
      state.copyWith(
        callStatus: CallStatus.idle,
        activePhone: '',
        isMuted: false,
        isSpeakerOn: false,
        callCount: 0,
        canMerge: false,
        clearError: true,
      ),
    );
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

  Future<void> _onMergeCalls(MergeCalls event, Emitter<DialerState> emit) async {
    try {
      await _callService.mergeCalls();
    } catch (e) {
      debugPrint('DialerBloc: mergeCalls error: $e');
    }
  }

  Future<void> _onSwapCalls(SwapCalls event, Emitter<DialerState> emit) async {
    try {
      await _callService.swapCalls();
    } catch (e) {
      debugPrint('DialerBloc: swapCalls error: $e');
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
