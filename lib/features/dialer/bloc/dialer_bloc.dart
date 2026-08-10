import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../contacts/models/contact_model.dart';
import '../services/native_call_service.dart';
import '../services/speed_dial_service.dart';
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
    on<SelectDialSim>(_onSelectDialSim);
    on<EndCall>(_onEndCall);
    on<AnswerCall>(_onAnswer);
    on<RejectCall>(_onReject);
    on<ToggleMute>(_onToggleMute);
    on<ToggleSpeaker>(_onToggleSpeaker);
    on<SelectAudioRoute>(_onSelectAudioRoute);
    on<HoldCall>(_onHold);
    on<SendDtmf>(_onSendDtmf);
    on<MergeCalls>(_onMergeCalls);
    on<SwapCalls>(_onSwapCalls);
    on<CallEventReceived>(_onCallEvent);
    on<SyncCallState>(_onSyncCallState);

    add(const DialerLoadContacts());
    _listenCallEvents();
    // Eight rows, read once: holding a key has to dial under the thumb, not
    // wait for a table.
    unawaited(SpeedDialService.instance.ensureLoaded());
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
        matchingNumbers: [],
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
          matchingNumbers: [],
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
          matchingNumbers: [],
          isNumberInContacts: false,
          isLoadingContacts: false,
        ),
      );
      return;
    }
    try {
      // Re-read rather than trusting the copy taken in the constructor: the
      // repository cache is invalidated by every contact write, so this is a
      // synchronous hand-back of the cached list in the normal case and a fresh
      // device read right after a contact was added. Filtering the constructor
      // snapshot is why a number saved from the call log or the "افزودن مخاطب"
      // row never turned into a suggestion until the app was restarted.
      _allContacts = await _contactRepository.getAllContacts();
      final matches = _contactRepository.matchPhoneDigits(
        _allContacts,
        event.query,
      );
      final inContacts = matches.any(
        (m) => _digitsOnly(m.number) == _digitsOnly(event.query),
      );
      emit(
        state.copyWith(
          matchingNumbers: matches,
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
      await _callService.makeCall(
        state.dialedNumber,
        subscriptionId: event.subscriptionId,
      );
      emit(
        state.copyWith(
          dialedNumber: '',
          matchingNumbers: [],
          isNumberInContacts: false,
          clearError: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  void _onSelectDialSim(SelectDialSim event, Emitter<DialerState> emit) {
    emit(state.copyWith(dialSubscriptionId: event.subscriptionId));
  }

  void _onCallEvent(CallEventReceived event, Emitter<DialerState> emit) {
    final info = event.callInfo;
    switch (info.event) {
      case NativeCallEvent.incoming:
        emit(
          state.copyWith(
            callStatus: CallStatus.incoming,
            activePhone: info.phone,
            activeName: info.name,
            activeSubscriptionId: info.subscriptionId,
          ),
        );
      case NativeCallEvent.ringing:
        // Outgoing dialing — carry the dialed number so the in-call screen
        // has something to display.
        emit(
          state.copyWith(
            callStatus: CallStatus.ringing,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
            activeName: info.name,
            activeSubscriptionId: info.subscriptionId,
          ),
        );
      case NativeCallEvent.active:
        emit(
          state.copyWith(
            callStatus: CallStatus.active,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
            activeName: info.name,
            isConference: info.isConference ?? state.isConference,
            activeSubscriptionId: info.subscriptionId,
          ),
        );
      case NativeCallEvent.onHold:
        emit(
          state.copyWith(
            callStatus: CallStatus.onHold,
            isConference: info.isConference ?? state.isConference,
          ),
        );
      case NativeCallEvent.disconnected:
        // reset call state — keypad و dialedNumber را حفظ کن
        emit(_idleState());
      case NativeCallEvent.callFailed:
        emit(
          state.copyWith(callStatus: CallStatus.idle, error: 'تماس برقرار نشد'),
        );
      case NativeCallEvent.audioState:
        // Telecom changed the route/mute outside our toggles (e.g. a headset
        // connected mid-call). This is the ONLY source of truth for the live
        // output — the picker must never guess it from its own last tap.
        emit(
          state.copyWith(
            isSpeakerOn: info.speaker ?? state.isSpeakerOn,
            isMuted: info.muted ?? state.isMuted,
            audioRoute: info.route ?? state.audioRoute,
            hasBluetooth: info.hasBluetooth ?? state.hasBluetooth,
            hasWiredHeadset: info.hasWiredHeadset ?? state.hasWiredHeadset,
            bluetoothName: info.bluetoothName,
          ),
        );
      case NativeCallEvent.callsChanged:
        // Zero live calls is the same news as DISCONNECTED, and it is the one
        // the native side can always deliver: onCallRemoved has to pick the
        // right call to report, this event only has to count. Without it a
        // missed DISCONNECTED left the call screen up with its timer running.
        if ((info.callCount ?? -1) == 0) {
          emit(_idleState());
          return;
        }
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

  /// Fire-and-forget: the authoritative route comes back as an AUDIO_STATE
  /// event from telecom. Echoing the tap into the state here would let the
  /// picker show an output that telecom refused (a headset that dropped
  /// between the sheet opening and the tap).
  Future<void> _onSelectAudioRoute(
    SelectAudioRoute event,
    Emitter<DialerState> emit,
  ) async {
    try {
      await _callService.setAudioRoute(event.route);
    } catch (e) {
      debugPrint('DialerBloc: setAudioRoute error: $e');
    }
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
        isConference: false,
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
        isConference: false,
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

  /// The call half of the state, wound back to "no call" — the keypad and the
  /// dialled number are deliberately kept.
  DialerState _idleState() => state.copyWith(
    callStatus: CallStatus.idle,
    activePhone: '',
    isMuted: false,
    isSpeakerOn: false,
    audioRoute: CallAudioRoute.earpiece,
    hasBluetooth: false,
    hasWiredHeadset: false,
    callCount: 0,
    canMerge: false,
    isConference: false,
    clearError: true,
  );

  /// Asks telecom whether a call actually exists and drops the call UI if it
  /// does not.
  ///
  /// The last line of defence, run whenever the app comes back to the
  /// foreground: every other path is an *event*, and a missed one strands the
  /// user on a call screen for a call that ended. Telecom's own answer cannot
  /// be missed.
  Future<void> _onSyncCallState(
    SyncCallState event,
    Emitter<DialerState> emit,
  ) async {
    if (state.callStatus == CallStatus.idle) return;
    bool inCall;
    try {
      inCall = await _callService.isInCall();
    } catch (e) {
      debugPrint('DialerBloc: isInCall failed: $e');
      return; // Never tear a live call's UI down on a channel error.
    }
    if (!inCall) {
      emit(_idleState());
      return;
    }
    // Still up: re-read the audio route too. A screen that mounted into an
    // ongoing call (cold start, or coming back from the shade) may never have
    // seen an AUDIO_STATE event, and the picker would show «گوشی» while the
    // audio is on a headset.
    final audio = await _callService.getAudioState();
    if (audio == null) return;
    emit(
      state.copyWith(
        isSpeakerOn: audio.speaker ?? state.isSpeakerOn,
        isMuted: audio.muted ?? state.isMuted,
        audioRoute: audio.route ?? state.audioRoute,
        hasBluetooth: audio.hasBluetooth ?? state.hasBluetooth,
        hasWiredHeadset: audio.hasWiredHeadset ?? state.hasWiredHeadset,
        bluetoothName: audio.bluetoothName,
      ),
    );
  }

  static String _digitsOnly(String s) => s.replaceAll(RegExp(r'[^\d]'), '');

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _callSub?.cancel();
    return super.close();
  }
}
