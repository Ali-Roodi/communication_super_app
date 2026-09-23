import 'dart:async';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter/foundation.dart';
import '../../../core/utils/persian_utils.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../contacts/models/contact_model.dart';
import '../services/auto_redial_policy.dart';
import '../services/native_call_service.dart';
import '../services/speed_dial_service.dart';
import 'dialer_event.dart';
import 'dialer_state.dart';

class DialerBloc extends Bloc<DialerEvent, DialerState> {
  final ContactRepository _contactRepository;
  final NativeCallService _callService;

  Timer? _debounceTimer;

  /// «تماس مجدد خودکار»: the countdown to the next attempt, and a watchdog on
  /// an attempt telecom never answered.
  Timer? _redialTimer;
  Timer? _redialWatchdog;

  /// A dialling call ended, but telecom has not said why yet — see
  /// [_redialAfter]. Cleared by every event that starts a call.
  bool _undecidedAttempt = false;
  List<ContactModel> _allContacts = [];
  StreamSubscription<CallInfo>? _callSub;

  DialerBloc(this._contactRepository, {NativeCallService? callService})
    : _callService = callService ?? NativeCallService.instance,
      super(const DialerState()) {
    // ── Keypad handlers ─────────────────────────────────────
    on<DialerLoadContacts>(_onLoadContacts);
    on<DialerNumberPressed>(_onNumberPressed);
    on<DialerNumberSet>(_onNumberSet);
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
    on<SelectAudioRoute>(_onSelectAudioRoute);
    on<HoldCall>(_onHold);
    on<DtmfKeyDown>(_onDtmfKeyDown);
    on<DtmfKeyUp>(_onDtmfKeyUp);
    on<MergeCalls>(_onMergeCalls);
    on<SwapCalls>(_onSwapCalls);
    on<CallEventReceived>(_onCallEvent);
    on<SyncCallState>(_onSyncCallState);
    on<CancelAutoRedial>(_onCancelAutoRedial);
    on<AutoRedialDue>(_onAutoRedialDue);

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

  /// Everything a phone can dial, and nothing else.
  ///
  /// Same rule the native side applies (`PhoneNumberUtils.stripSeparators`):
  /// `*` and `#` are USSD/MMI, `,` and `;` are the post-dial pause/wait stored
  /// in contact numbers, and a pasted number arrives full of spaces, dashes and
  /// parentheses. Anything else — a name in front of the number, a «تماس:»
  /// label — is dropped rather than refused, because a clipboard almost never
  /// holds a bare number.
  static final RegExp _nonDialable = RegExp(r'[^0-9+*#,;]');

  static String sanitizeDialable(String raw) =>
      PersianUtils.toEnglishNumber(raw).replaceAll(_nonDialable, '');

  void _onNumberSet(DialerNumberSet event, Emitter<DialerState> emit) {
    final cleaned = sanitizeDialable(event.number);
    if (cleaned.isEmpty) return;
    final next = event.append ? state.dialedNumber + cleaned : cleaned;
    _debounceTimer?.cancel();
    emit(
      state.copyWith(
        dialedNumber: next,
        isLoadingContacts: true,
        clearError: true,
      ),
    );
    // No debounce: this is one deliberate action, not a burst of keystrokes.
    add(DialerFilterContacts(next));
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
      // A number dialled by hand supersedes any redial still counting down.
      _stopRedialTimers();
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
          clearAutoRedial: true,
        ),
      );
    } catch (e) {
      emit(state.copyWith(error: e.toString()));
    }
  }

  /// Whether [info] is authoritative about *who* the call is with.
  ///
  /// Telecom sends state changes for a call it has already named; only an event
  /// that carries the number identifies the party, and an event without one
  /// (an audio-state or hold change) must leave the identity alone.
  static bool _namesTheParty(CallInfo info) => info.phone.isNotEmpty;

  /// The caller's name as this event reports it — empty folded to null, so
  /// «no contact» is one value and not two.
  static String? _nameOf(CallInfo info) {
    final name = info.name;
    return (name == null || name.isEmpty) ? null : name;
  }

  void _onCallEvent(CallEventReceived event, Emitter<DialerState> emit) {
    final info = event.callInfo;
    // The identity fields are REPLACED by an event that carries a number, never
    // merged into what was there. `copyWith` reads null as "leave it alone", so
    // without the explicit clears a call from an unsaved number kept the name —
    // and the SIM badge — of the previous caller.
    final name = _nameOf(info);
    final identifies = _namesTheParty(info);
    final clearName = identifies && name == null;
    final clearSim = identifies && info.subscriptionId == null;
    switch (info.event) {
      case NativeCallEvent.incoming:
        // Somebody calling in ends any redial series — the phone is busy with
        // something the user wants more.
        _stopRedialTimers();
        _undecidedAttempt = false;
        emit(
          state.copyWith(
            callStatus: CallStatus.incoming,
            activePhone: info.phone,
            showIncomingScreen: info.showScreen,
            dtmfDigits: _dtmfDigitsFor(info.phone),
            activeName: name,
            clearActiveName: clearName,
            activeSubscriptionId: info.subscriptionId,
            clearActiveSubscriptionId: clearSim,
            clearAutoRedial: true,
          ),
        );
      case NativeCallEvent.ringing:
        // Outgoing dialing — carry the dialed number so the in-call screen
        // has something to display.
        _redialWatchdog?.cancel();
        _undecidedAttempt = false;
        // A call dialling while the series is still counting down, or to
        // somebody else, was placed by hand (every screen dials through
        // `NativeCallService` directly): the series is over. Our own attempt
        // has `dueAt` cleared before it is placed, so it passes.
        final foreign = _redialSupersededBy(info.phone);
        if (foreign) _stopRedialTimers();
        emit(
          state.copyWith(
            callStatus: CallStatus.ringing,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
            dtmfDigits: _dtmfDigitsFor(info.phone),
            activeName: name,
            clearActiveName: clearName,
            activeSubscriptionId: info.subscriptionId,
            clearActiveSubscriptionId: clearSim,
            clearAutoRedial: foreign,
          ),
        );
      case NativeCallEvent.active:
        // Connected — whether to a person or to the carrier's announcement,
        // the series has done its job. A call that connected is never
        // redialled: an eight-second «بعداً زنگ می‌زنم» is a conversation, not
        // a failed attempt.
        _stopRedialTimers();
        _undecidedAttempt = false;
        emit(
          state.copyWith(
            callStatus: CallStatus.active,
            activePhone: info.phone.isNotEmpty ? info.phone : null,
            dtmfDigits: _dtmfDigitsFor(info.phone),
            activeName: name,
            clearActiveName: clearName,
            isConference: info.isConference ?? state.isConference,
            activeSubscriptionId: info.subscriptionId,
            clearActiveSubscriptionId: clearSim,
            // Telecom's own connect time. Authoritative, and the reason the
            // duration survives minimizing the call screen and a cold start
            // into a call that was already running.
            callConnectedAt: info.connectedAt,
            clearAutoRedial: true,
          ),
        );
      case NativeCallEvent.onHold:
        emit(
          state.copyWith(
            callStatus: CallStatus.onHold,
            isConference: info.isConference ?? state.isConference,
            callConnectedAt: info.connectedAt,
          ),
        );
      case NativeCallEvent.disconnected:
        // Decided BEFORE the state is wound back: whether this was a failed
        // outgoing attempt is written in the status the call had a moment ago.
        final verdict = _redialAfter(info);
        // reset call state — keypad و dialedNumber را حفظ کن
        //
        // The series is cleared only by a verdict against it. One teardown
        // produces up to three DISCONNECTEDs (the state change, onCallRemoved,
        // republishCurrent), and the device trace showed the second one —
        // status already idle, so «not a failed attempt» — wiping the
        // countdown the first had just started.
        emit(
          _idleState().copyWith(
            autoRedial: verdict.next,
            clearAutoRedial: verdict.decided && verdict.next == null,
          ),
        );
        if (verdict.next != null) _scheduleRedial();
      case NativeCallEvent.callFailed:
        // Through `_idleState` like every other teardown: leaving the identity
        // fields behind is what let the next call inherit this one's name.
        _stopRedialTimers();
        emit(
          _idleState().copyWith(
            error: 'تماس برقرار نشد',
            clearAutoRedial: true,
          ),
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
      case NativeCallEvent.showCallUi:
      // A request to re-open the call screen, not a state change —
      // CallUiCoordinator listens to NativeCallService.onShowCallUi.
      case NativeCallEvent.unknown:
        // An event name this build does not know. Deliberately nothing: it
        // used to be parsed as DISCONNECTED and tear a live call's UI down.
        break;
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
    //
    // Hanging up on a dialling attempt is also the end of a redial series:
    // the DISCONNECTED that follows finds the status already idle, so it
    // cannot schedule another one — and the user said stop.
    _stopRedialTimers();
    _undecidedAttempt = false;
    emit(
      state.copyWith(
        callStatus: CallStatus.idle,
        activePhone: '',
        clearActiveName: true,
        clearActiveSubscriptionId: true,
        isMuted: false,
        isSpeakerOn: false,
        callCount: 0,
        canMerge: false,
        isConference: false,
        clearError: true,
        clearCallConnectedAt: true,
        clearAutoRedial: true,
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
    _stopRedialTimers();
    _undecidedAttempt = false;
    emit(
      state.copyWith(
        callStatus: CallStatus.idle,
        activePhone: '',
        clearActiveName: true,
        clearActiveSubscriptionId: true,
        isMuted: false,
        isSpeakerOn: false,
        callCount: 0,
        canMerge: false,
        isConference: false,
        clearError: true,
        clearCallConnectedAt: true,
        clearAutoRedial: true,
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

  /// The digit is recorded in the state, not in the call screen: the screen is
  /// torn down and re-pushed by `CallUiCoordinator` whenever the user leaves
  /// and comes back, and Google Phone keeps what was typed for the whole call.
  Future<void> _onDtmfKeyDown(
    DtmfKeyDown event,
    Emitter<DialerState> emit,
  ) async {
    emit(state.copyWith(dtmfDigits: state.dtmfDigits + event.digit));
    try {
      await _callService.startDtmf(event.digit);
    } catch (e) {
      debugPrint('DialerBloc: startDtmf error: $e');
    }
  }

  Future<void> _onDtmfKeyUp(DtmfKeyUp event, Emitter<DialerState> emit) async {
    try {
      await _callService.stopDtmf();
    } catch (e) {
      debugPrint('DialerBloc: stopDtmf error: $e');
    }
  }

  Future<void> _onMergeCalls(
    MergeCalls event,
    Emitter<DialerState> emit,
  ) async {
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
  /// What [DialerState.dtmfDigits] becomes on a call event naming [phone]:
  /// unchanged (null) while it is the same party, cleared when the event is
  /// about somebody else — a new call, or the other leg after a swap. The
  /// digits typed for one call must never show up on the next one's keypad.
  String? _dtmfDigitsFor(String phone) =>
      phone.isNotEmpty && phone != state.activePhone ? '' : null;

  DialerState _idleState() => state.copyWith(
    callStatus: CallStatus.idle,
    showIncomingScreen: true,
    activePhone: '',
    dtmfDigits: '',
    clearActiveName: true,
    clearActiveSubscriptionId: true,
    isMuted: false,
    isSpeakerOn: false,
    audioRoute: CallAudioRoute.earpiece,
    hasBluetooth: false,
    hasWiredHeadset: false,
    callCount: 0,
    canMerge: false,
    isConference: false,
    clearError: true,
    clearCallConnectedAt: true,
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

  // ── «تماس مجدد خودکار» ─────────────────────────────────────
  //
  // A failed outgoing call is dialled again, after a visible countdown, up to
  // «تعداد تلاش‌ها» times. Off unless the user switched it on. What counts as
  // *failed* is deliberately narrow — see [_redialAfter] — because a phone
  // that dials by itself when it should not is far worse than one that does
  // not dial when it could have.

  /// Guards an attempt telecom never answered: `makeCall` returned, no call
  /// was ever added, and nothing would otherwise take the series down.
  static const Duration _redialWatchdogTimeout = Duration(seconds: 20);

  /// What a DISCONNECTED event means for the series: [_RedialVerdict.next] is
  /// the attempt to schedule, and [_RedialVerdict.decided] says whether the
  /// event was a verdict on a dialling call at all — a duplicate DISCONNECTED
  /// of the same teardown, arriving with the status already idle, is not,
  /// and must leave a countdown the first one started alone.
  ///
  /// Read against the state *before* it is wound back to idle:
  ///
  /// * the bloc was following an outgoing call that never went active
  ///   (`ringing`/`connecting`). This excludes incoming calls of every kind
  ///   without trusting the native direction (pre-Q it is inferred, and wrongly
  ///   so at DISCONNECTED), and it excludes «پایان» during dialling, which
  ///   resets the status before this event arrives;
  /// * telecom agrees it never connected, and says why — busy, dropped by the
  ///   far end, or a network error. A carrier that connects the caller to an
  ///   announcement («مشترک مورد نظر پاسخگو نمی‌باشد») makes the call ACTIVE
  ///   first, and such a call is not retried: from here that is
  ///   indistinguishable from a person picking up.
  _RedialVerdict _redialAfter(CallInfo info) {
    final prior = state.autoRedial;
    // The status the call had a moment ago — or, when this is the second
    // DISCONNECTED of the same teardown, the one it had before the first.
    final wasDialling =
        state.callStatus == CallStatus.ringing ||
        state.callStatus == CallStatus.connecting ||
        _undecidedAttempt;
    final attempt = (prior?.attempt ?? 0) + 1;
    final maxAttempts = prior?.maxAttempts ?? AutoRedialPolicy.maxAttempts;
    final phone = info.phone.isNotEmpty ? info.phone : state.activePhone;
    final candidate =
        AutoRedialPolicy.enabled &&
        info.direction == 'outgoing' &&
        wasDialling &&
        info.connectedAt == null &&
        phone.isNotEmpty;
    // Telecom's first DISCONNECTED can arrive before the cause is filled in
    // (`code=UNKNOWN`; the device trace showed exactly that, with the real
    // cause following from onCallRemoved a beat later). That event winds the
    // status back to idle, so the *second* event would no longer look like a
    // dialling call — remember that it was, and decide when the cause comes.
    // Nothing else can be mistaken for it: a new call of any kind clears the
    // flag before its own teardown.
    if (candidate && info.disconnectCause == CallDisconnectCause.unknown) {
      _undecidedAttempt = true;
      debugPrint('[redial] disconnected with no cause yet — waiting for it');
      return const _RedialVerdict(next: null, decided: false);
    }
    _undecidedAttempt = false;
    final failed = candidate && info.disconnectCause.isRetryable;
    final again = failed && attempt <= maxAttempts;
    debugPrint(
      '[redial] disconnected cause=${info.disconnectCause.name} '
      'reason=${info.disconnectReason} direction=${info.direction} '
      'connected=${info.connectedAt != null} status=${state.callStatus.name} '
      'enabled=${AutoRedialPolicy.enabled} attempt=$attempt/$maxAttempts '
      '-> ${again
          ? 'redial'
          : failed
          ? 'give up'
          : 'not a failed attempt'}',
    );
    if (!again) return _RedialVerdict(next: null, decided: wasDialling);
    return _RedialVerdict(
      decided: true,
      next: AutoRedial(
        phone: phone,
        // The SIM the failed call went out on — the retry must not re-ask, and
        // it must not silently switch cards either.
        subscriptionId: prior?.subscriptionId ?? state.activeSubscriptionId,
        attempt: attempt,
        maxAttempts: maxAttempts,
        dueAt: DateTime.now().add(AutoRedialPolicy.delay),
      ),
    );
  }

  /// Whether a call now dialling to [phone] is *not* our own attempt.
  bool _redialSupersededBy(String phone) {
    final redial = state.autoRedial;
    if (redial == null) return false;
    if (redial.isCountingDown) return true;
    if (phone.isEmpty) return false;
    return _digitsOnly(phone) != _digitsOnly(redial.phone);
  }

  void _scheduleRedial() {
    _stopRedialTimers();
    _redialTimer = Timer(
      AutoRedialPolicy.delay,
      () => add(const AutoRedialDue()),
    );
  }

  void _stopRedialTimers() {
    _redialTimer?.cancel();
    _redialTimer = null;
    _redialWatchdog?.cancel();
    _redialWatchdog = null;
  }

  void _onCancelAutoRedial(CancelAutoRedial event, Emitter<DialerState> emit) {
    _stopRedialTimers();
    if (state.autoRedial == null) return;
    emit(state.copyWith(clearAutoRedial: true));
  }

  Future<void> _onAutoRedialDue(
    AutoRedialDue event,
    Emitter<DialerState> emit,
  ) async {
    final redial = state.autoRedial;
    // Cancelled, or already placed, since the timer was set.
    if (redial == null || !redial.isCountingDown) return;
    // Something else is on the phone (a call came in during the countdown and
    // the event that should have cleared the series has not landed yet).
    if (state.callStatus != CallStatus.idle) {
      emit(state.copyWith(clearAutoRedial: true));
      return;
    }
    // Marked as placed BEFORE the call goes out, so the RINGING it produces is
    // recognised as ours.
    emit(state.copyWith(autoRedial: redial.placed()));
    try {
      await _callService.makeCall(
        redial.phone,
        subscriptionId: redial.subscriptionId,
      );
    } catch (e) {
      debugPrint('[redial] makeCall failed: $e');
      emit(state.copyWith(clearAutoRedial: true, error: 'تماس برقرار نشد'));
      return;
    }
    _redialWatchdog = Timer(_redialWatchdogTimeout, () {
      final now = state.autoRedial;
      if (now != null &&
          !now.isCountingDown &&
          state.callStatus == CallStatus.idle) {
        debugPrint('[redial] telecom never answered the attempt — giving up');
        add(const CancelAutoRedial());
      }
    });
  }

  @override
  Future<void> close() {
    _debounceTimer?.cancel();
    _stopRedialTimers();
    _callSub?.cancel();
    return super.close();
  }
}

/// What one DISCONNECTED event means for «تماس مجدد خودکار».
class _RedialVerdict {
  /// The attempt to schedule, or null.
  final AutoRedial? next;

  /// Whether the event was a verdict on a dialling call at all. False for the
  /// duplicate DISCONNECTEDs a single teardown produces (status already idle)
  /// and for a causeless first one — neither may touch a running series.
  final bool decided;

  const _RedialVerdict({required this.next, required this.decided});
}
