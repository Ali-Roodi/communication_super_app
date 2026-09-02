import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:communication_super_app/core/navigation/call_ui_coordinator.dart';
import 'package:communication_super_app/core/navigation/return_to_call_bar.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../services/native_call_service.dart';
import '../widgets/dialer_bottom_sheet.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';
import '../../contacts/repositories/contact_repository.dart';

const Color _kBg = Color(0xFF1C1B1F);

/// Cap on the in-call keypad's width. Without it the three columns stretch to
/// the edges of a large screen and stop reading as a keypad.
const double _kKeypadMaxWidth = 320;

/// Width of «بستن» under the in-call keypad, and of the empty box that
/// balances it. Wide enough for the word on one line at 16 sp.
const double _kCloseButtonWidth = 96;
const Color _kActiveTint = AppColors.googleBlueDark; // #8AB4F8

class InCallScreen extends StatefulWidget {
  final String phone;
  final String? contactName;

  const InCallScreen({super.key, required this.phone, this.contactName});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  /// Repaints the duration once a second. The elapsed time itself is derived
  /// from telecom's connect time (`DialerState.callConnectedAt`), never
  /// accumulated here — this screen can be minimized and re-opened, and a
  /// counter would restart at zero every time (as it also did on a cold start
  /// into a call that had already been running for minutes).
  Timer? _timer;

  /// Resolved device-contact identity (name + photo) for the phone currently
  /// in the foreground. Re-resolved whenever the active call switches (add a
  /// second call, swap) so the header tracks the live participant instead of
  /// staying on the number the screen was first opened with.
  String? _resolvedName;
  Uint8List? _avatar;
  String? _resolvedFor;

  @override
  void initState() {
    super.initState();
    _resolveContact(widget.phone);
    _ensureSimRoster();
  }

  /// The number of the call currently shown — the bloc's activePhone once it
  /// arrives (covers add-call/swap), else the number the screen opened with.
  String _currentPhone(DialerState state) =>
      state.activePhone.isNotEmpty ? state.activePhone : widget.phone;

  Future<void> _resolveContact(String phone) async {
    if (phone.isEmpty || phone == _resolvedFor) return;
    _resolvedFor = phone;
    final repo = ContactRepository();
    final contact = await repo.getContactByPhoneNumber(phone);
    if (!mounted || _resolvedFor != phone) return;
    setState(() {
      _resolvedName = contact != null && contact.name.isNotEmpty
          ? contact.name
          : null;
    });
    // Avatars are no longer held in the bulk cache — fetch this one contact's
    // thumbnail lazily by id.
    if (contact == null) return;
    final avatar = await repo.getContactThumbnail(contact.id);
    if (!mounted || _resolvedFor != phone || avatar == null) return;
    setState(() => _avatar = avatar);
  }

  /// Starts the once-a-second repaint. Only the tick lives here; what it
  /// prints comes from telecom's connect time.
  void _ensureTimerStarted() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The roster may be unread when a call wakes the process; loading it here
  /// is what lets [SimAware] fill the carrier line in a frame later.
  void _ensureSimRoster() => SimService.instance.ensureLoaded();

  /// The carrier line under the top of the call screen — or **nothing**.
  ///
  /// It exists to say *which card* a call is on, so it is drawn only when that
  /// is a real question and there is a real answer: two SIMs, and a roster that
  /// can name the one in use. On a single-SIM phone, a VoIP call, or a card the
  /// roster cannot name it used to print the bare word «سیم‌کارت», which
  /// answers nothing and reads like a label whose value failed to load.
  String? _simLine(DialerState state) {
    if (!SimService.isMultiSim) return null;
    final sim = SimService.byId(state.activeSubscriptionId);
    if (sim == null) return null;
    final name = sim.name.trim();
    return name.isEmpty ? sim.slotLabel : '${sim.slotLabel} · $name';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      // Back does NOT end the call — it puts the screen away, exactly like
      // Google Phone. The call keeps running and comes back through the green
      // «بازگشت به تماس» bar or the shade's «تماس در جریان» card. Hanging up on
      // a stray back gesture is the behaviour this replaces.
      child: PopScope(
        canPop: false,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) return;
          if (_handleBack()) return;
          CallUiCoordinator.minimize();
        },
        child: _buildBody(context),
      ),
    );
  }

  Widget _buildBody(BuildContext context) {
    return BlocConsumer<DialerBloc, DialerState>(
      listenWhen: (prev, curr) =>
          prev.callStatus != curr.callStatus ||
          prev.activePhone != curr.activePhone,
      listener: (context, state) {
        if (state.callStatus == CallStatus.active) _ensureTimerStarted();
        // The call ended: stop counting immediately. The route lingers ~600 ms
        // so the keyguard handover doesn't flash the app's own UI, and a timer
        // still ticking through it reads as "the call is somehow still up".
        if (state.callStatus == CallStatus.idle) {
          _timer?.cancel();
          _timer = null;
        }
        // Foreground call switched (add-call / swap) — refresh the identity.
        _resolveContact(_currentPhone(state));
      },
      builder: (context, state) {
        final onHold = state.callStatus == CallStatus.onHold;
        final dialing =
            state.callStatus == CallStatus.ringing ||
            state.callStatus == CallStatus.connecting;
        // Screen can mount when the call is already active (cold start into
        // an ongoing call) — start counting right away in that case.
        if (state.callStatus == CallStatus.active) _ensureTimerStarted();

        final phone = _currentPhone(state);
        // Merged conference: show the group title, not a single participant.
        final conference = state.isConference;
        // The passed-in contactName only applies to the number the screen
        // opened with; once the active call switches, use the resolved name.
        final passedName = phone == widget.phone ? widget.contactName : null;
        final name = conference ? 'تماس گروهی' : (passedName ?? _resolvedName);
        // The call went away while the keypad was open (the other side hung
        // up): drop back to the call screen so «تماس پایان یافت» is what the
        // user is left looking at, not a keypad wired to nothing.
        if (_showKeypad && state.callStatus == CallStatus.idle) {
          _showKeypad = false;
        }
        return Scaffold(
          backgroundColor: _kBg,
          body: SafeArea(
            child: _showKeypad
                ? _buildKeypad(context, phone, name)
                : Column(
              children: [
                // «کوچک کردن» — the discoverable half of the back gesture.
                // Google Phone puts the same chevron here, and without it the
                // only way to reach the app during a call is a gesture with
                // nothing on screen to suggest it.
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: IconButton(
                    icon: const Icon(
                      Icons.keyboard_arrow_down,
                      color: Colors.white70,
                      size: 30,
                    ),
                    tooltip: 'کوچک کردن',
                    onPressed: CallUiCoordinator.minimize,
                  ),
                ),
                const Spacer(flex: 2),
                // The SIM this call is on — Google Phone's carrier line.
                // Absent unless it has something to say (see [_simLine]).
                // Wrapped in [SimAware] because a call can mount this screen
                // before the roster is readable — a call routinely wakes a
                // dead process — and the line would then stay blank for the
                // whole call.
                SimAware(
                  builder: (context, _, _) {
                    final line = _simLine(state);
                    if (line == null) return const SizedBox(height: 8);
                    return Column(
                      children: [
                        Text(
                          line,
                          style: const TextStyle(
                            color: Colors.white38,
                            fontSize: 13,
                          ),
                        ),
                        const SizedBox(height: 24),
                      ],
                    );
                  },
                ),
                _buildAvatar(conference: conference),
                const SizedBox(height: 20),
                Text(
                  name ?? PersianUtils.displayPhone(phone),
                  // LTR keeps the grouped number order (0919 096 1805)
                  // inside the RTL screen.
                  textDirection: name == null ? TextDirection.ltr : null,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w300,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (name != null && !conference) ...[
                  const SizedBox(height: 6),
                  Text(
                    PersianUtils.displayPhone(phone),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(color: Colors.white54, fontSize: 15),
                  ),
                ],
                const SizedBox(height: 10),
                state.callStatus == CallStatus.idle
                    ? const Text(
                        'تماس پایان یافت',
                        style: TextStyle(color: Colors.white54, fontSize: 16),
                      )
                    : onHold
                    ? const _PulsingText('در انتظار')
                    : dialing
                    ? const _PulsingText('در حال برقراری تماس…')
                    : Text(
                        formatCallDuration(state.callConnectedAt),
                        style: const TextStyle(
                          color: Colors.white70,
                          fontSize: 16,
                        ),
                      ),
                const Spacer(flex: 3),
                _buildControlGrid(context, state),
                const SizedBox(height: 32),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Back while the keypad is up closes the keypad, not the screen — the same
  /// thing Google Phone does, and the reason the [PopScope] above is asked.
  bool _handleBack() {
    if (!_showKeypad) return false;
    _closeKeypad();
    return true;
  }

  Widget _buildAvatar({bool conference = false}) {
    return Container(
      width: 96,
      height: 96,
      decoration: const BoxDecoration(
        color: Colors.white12,
        shape: BoxShape.circle,
      ),
      clipBehavior: Clip.antiAlias,
      child: conference
          ? const Icon(Icons.group, size: 52, color: Colors.white60)
          : _avatar != null
          ? Image.memory(_avatar!, fit: BoxFit.cover)
          : const Icon(Icons.person, size: 52, color: Colors.white60),
    );
  }

  Widget _buildControlGrid(BuildContext context, DialerState state) {
    final bloc = context.read<DialerBloc>();
    final onHold = state.callStatus == CallStatus.onHold;

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _ControlButton(
                icon: state.isMuted ? Icons.mic_off : Icons.mic,
                label: 'بی‌صدا',
                active: state.isMuted,
                onTap: () => bloc.add(const ToggleMute()),
              ),
              _ControlButton(
                icon: Icons.dialpad,
                label: 'صفحه‌کلید',
                active: false,
                onTap: _openKeypad,
              ),
              // The button says where the audio IS, not just whether the
              // speaker is on: with a headset connected «بلندگو» off was the
              // only thing the screen said while the sound was in someone's
              // ear. Long-press (and a tap while routed to a headset) opens
              // the full picker — a plain toggle cannot express three outputs.
              _ControlButton(
                icon: switch (state.audioRoute) {
                  CallAudioRoute.bluetooth => Icons.bluetooth_audio,
                  CallAudioRoute.wired => Icons.headset_outlined,
                  CallAudioRoute.speaker => Icons.volume_up,
                  CallAudioRoute.earpiece => Icons.volume_down,
                },
                label: switch (state.audioRoute) {
                  CallAudioRoute.bluetooth => 'بلوتوث',
                  CallAudioRoute.wired => 'هدست',
                  _ => 'بلندگو',
                },
                active: state.audioRoute != CallAudioRoute.earpiece,
                onTap: () {
                  if (state.hasBluetooth || state.hasWiredHeadset) {
                    _showAudioPicker(context, state);
                  } else {
                    bloc.add(const ToggleSpeaker());
                  }
                },
                onLongPress: () => _showAudioPicker(context, state),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Second call in progress: conference controls (ادغام / تعویض).
          //
          // `isConference` is checked as well as the count: once the two legs
          // are merged they become children of one conference call, and until
          // telecom finishes re-parenting them the count can still read 2 —
          // which is what left «ادغام تماس» sitting on top of an already
          // merged call.
          if (state.callCount > 1 && !state.isConference) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ControlButton(
                  icon: Icons.call_merge,
                  label: 'ادغام تماس',
                  active: false,
                  // Dimmed rather than absent while telecom says the two legs
                  // cannot be conferenced (one still dialing): a button that
                  // appears and disappears under the thumb is worse than one
                  // that is visibly not ready yet.
                  enabled: state.canMerge,
                  onTap: () => bloc.add(const MergeCalls()),
                ),
                _ControlButton(
                  icon: Icons.swap_calls,
                  label: 'تعویض تماس',
                  active: false,
                  onTap: () => bloc.add(const SwapCalls()),
                ),
                const SizedBox(width: 84),
              ],
            ),
            const SizedBox(height: 28),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Telecom holds at most two top-level calls; a third dial would
              // be refused with nothing on screen to explain it. Once they are
              // merged into a conference there is room again.
              _ControlButton(
                icon: Icons.add_call,
                label: 'افزودن تماس',
                active: false,
                enabled: state.callCount < 2,
                onTap: () => showDialerBottomSheet(context),
              ),
              _ControlButton(
                icon: Icons.pause,
                label: 'نگه‌داشتن',
                active: onHold,
                onTap: () => bloc.add(HoldCall(hold: !onHold)),
              ),
              _EndCallButton(onTap: () => bloc.add(const EndCall())),
            ],
          ),
        ],
      ),
    );
  }

  // ── DTMF keypad ─────────────────────────────────────────────────────────────
  //
  // Part of THIS screen, not a modal route on top of it, and that is a bug fix.
  //
  // It used to be a `showModalBottomSheet`, which put a second route above the
  // in-call route — and the in-call route is owned by `CallUiCoordinator`,
  // which moves it around behind the user's back. Coming back to the app
  // through the shade's «تماس در جریان» card runs `_restore` →
  // `_bringCallRouteToTop` → `popUntil(… == callRoute)`, and re-entering a call
  // that changed state re-pushes the screen and `removeRoute`s the old one.
  // Either way the sheet is torn off a route that is being rearranged
  // underneath it, and what the tester saw was the aftermath: the keypad opened
  // and its keys did nothing — the digits were being typed into a
  // `StatefulBuilder` belonging to a dead route.
  //
  // Held in the state instead, the pad is exactly as durable as the call
  // screen: it survives every push/pop the coordinator performs, it is torn
  // down with the call, and it is what Google Phone does — its in-call keypad
  // replaces the screen's contents rather than sliding a sheet over them.

  /// Whether the keypad is showing instead of the avatar + control grid.
  bool _showKeypad = false;

  /// Digits typed on the in-call keypad since it was opened. Display only —
  /// each key is transmitted the moment it is pressed.
  String _dtmfEntered = '';

  void _openKeypad() => setState(() {
    _showKeypad = true;
    _dtmfEntered = '';
  });

  void _closeKeypad() => setState(() => _showKeypad = false);

  /// The in-call keypad, laid out like the call screen it replaces: header at
  /// the top, the grid in the middle of what is left, «پایان» at the bottom.
  ///
  /// The proportions matter and are the same `Spacer` flexes the call screen
  /// itself uses. A plain `Column` of naturally-sized children (which is what
  /// this was at first) stacks everything against the top of the screen and
  /// leaves a black third underneath, and `spaceBetween` on a row of three
  /// 64 dp keys spreads them to the screen edges — a keypad has to read as a
  /// grid, so the columns are equal-width `Expanded` cells inside a box capped
  /// at [_kKeypadMaxWidth] and centred.
  Widget _buildKeypad(BuildContext context, String phone, String? name) {
    final bloc = context.read<DialerBloc>();
    return Column(
      children: [
        const SizedBox(height: 12),
        // Who is on the line stays on screen — Google Phone keeps the header
        // above its keypad, and without it the user is typing into a black
        // rectangle with no idea which call it reaches.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Text(
            name ?? PersianUtils.displayPhone(phone),
            textDirection: name == null ? TextDirection.ltr : null,
            style: const TextStyle(color: Colors.white70, fontSize: 17),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 20),
        // The tones typed so far. Scrolls rather than ellipsises: an IVR menu
        // can take a long string and the digit that matters is the last one,
        // so the view is pinned to the end.
        SizedBox(
          height: 40,
          child: Directionality(
            // A number, not a sentence — left to right whatever the screen is.
            textDirection: TextDirection.ltr,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Center(
                child: Text(
                  PersianUtils.toPersianNumber(_dtmfEntered),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    letterSpacing: 2,
                  ),
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        Directionality(
          textDirection: TextDirection.ltr,
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: _kKeypadMaxWidth),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    for (final row in _dtmfRows)
                      Row(
                        children: [
                          for (final k in row)
                            Expanded(
                              child: Center(
                                child: _DtmfKey(
                                  display: k[0],
                                  onTap: () {
                                    bloc.add(SendDtmf(k[1]));
                                    setState(() => _dtmfEntered += k[1]);
                                  },
                                ),
                              ),
                            ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
        const Spacer(),
        // «بستن» sits opposite nothing, so «پایان» stays centred on the screen
        // exactly where it is on the call screen behind this one.
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: Row(
            children: [
              // Balances «بستن» so «پایان» stays centred on the screen, in the
              // same place it occupies on the call screen behind this one.
              const SizedBox(width: _kCloseButtonWidth),
              const Spacer(),
              _EndCallButton(onTap: () => bloc.add(const EndCall())),
              const Spacer(),
              SizedBox(
                width: _kCloseButtonWidth,
                child: TextButton(
                  onPressed: _closeKeypad,
                  // Zero padding, and that is not a style choice: a
                  // `TextButton`'s default 16 dp each side left «بستن» 52 dp to
                  // render four Persian characters in, and it wrapped onto a
                  // second line under the button.
                  style: TextButton.styleFrom(
                    padding: EdgeInsets.zero,
                    minimumSize: const Size(_kCloseButtonWidth, 48),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: const Text(
                    'بستن',
                    maxLines: 1,
                    style: TextStyle(color: Colors.white70, fontSize: 16),
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 32),
      ],
    );
  }

  // ── Audio output picker (speaker long-press) ─────────────────────────────────

  /// Google Phone's output picker.
  ///
  /// Every row is driven by telecom's `supportedRouteMask` and its live route:
  /// a headset that is not connected is not listed at all, and the tick sits on
  /// whatever the audio is actually coming out of. The old sheet was three
  /// hardcoded rows whose «بلوتوث» always answered «دستگاه بلوتوثی یافت نشد» —
  /// with a headset connected and playing.
  void _showAudioPicker(BuildContext context, DialerState state) {
    final bloc = context.read<DialerBloc>();
    showModalBottomSheet<void>(
      context: context,
      // Rebuilds with the state: a headset connecting or dropping while the
      // sheet is open has to move the tick.
      builder: (sheetCtx) => BlocProvider.value(
        value: bloc,
        child: BlocBuilder<DialerBloc, DialerState>(
          buildWhen: (a, b) =>
              a.audioRoute != b.audioRoute ||
              a.hasBluetooth != b.hasBluetooth ||
              a.hasWiredHeadset != b.hasWiredHeadset ||
              a.bluetoothName != b.bluetoothName,
          builder: (_, live) => Directionality(
            textDirection: TextDirection.rtl,
            child: SafeArea(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final row in _audioRows(live))
                    ListTile(
                      leading: Icon(row.icon),
                      title: Text(row.label),
                      trailing: live.audioRoute == row.route
                          ? const Icon(
                              Icons.check,
                              color: AppColors.callAnswerGreen,
                            )
                          : null,
                      onTap: () {
                        bloc.add(SelectAudioRoute(row.route));
                        Navigator.of(sheetCtx).pop();
                      },
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The outputs this call actually has. «گوشی» and «بلندگو» always exist on a
  /// phone; the headsets are listed only while telecom reports them.
  List<({CallAudioRoute route, IconData icon, String label})> _audioRows(
    DialerState state,
  ) => [
    (route: CallAudioRoute.earpiece, icon: Icons.phone_in_talk, label: 'گوشی'),
    (route: CallAudioRoute.speaker, icon: Icons.volume_up, label: 'بلندگو'),
    if (state.hasWiredHeadset)
      (
        route: CallAudioRoute.wired,
        icon: Icons.headset_outlined,
        label: 'هدست سیمی',
      ),
    if (state.hasBluetooth)
      (
        route: CallAudioRoute.bluetooth,
        icon: Icons.bluetooth_audio,
        // Naming the device is what tells two paired headsets apart.
        label: state.bluetoothName == null
            ? 'بلوتوث'
            : 'بلوتوث · ${state.bluetoothName}',
      ),
  ];

  static const List<List<List<String>>> _dtmfRows = [
    [
      ['۱', '1'],
      ['۲', '2'],
      ['۳', '3'],
    ],
    [
      ['۴', '4'],
      ['۵', '5'],
      ['۶', '6'],
    ],
    [
      ['۷', '7'],
      ['۸', '8'],
      ['۹', '9'],
    ],
    [
      ['*', '*'],
      ['۰', '0'],
      ['#', '#'],
    ],
  ];
}

// ── Pulsing "on hold" text ────────────────────────────────────────────────────

class _PulsingText extends StatefulWidget {
  final String text;
  const _PulsingText(this.text);

  @override
  State<_PulsingText> createState() => _PulsingTextState();
}

class _PulsingTextState extends State<_PulsingText>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return FadeTransition(
      opacity: Tween<double>(begin: 0.4, end: 1.0).animate(_ctrl),
      child: Text(
        widget.text,
        style: const TextStyle(color: _kActiveTint, fontSize: 16),
      ),
    );
  }
}

// ── Control button ────────────────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final bool enabled;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.enabled = true,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Opacity(
        opacity: enabled ? 1 : 0.4,
        child: GestureDetector(
          onTap: enabled ? onTap : null,
          onLongPress: enabled ? onLongPress : null,
          child: Column(
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  color: active ? _kActiveTint : Colors.white12,
                  shape: BoxShape.circle,
                ),
                child: Icon(
                  icon,
                  color: active ? _kBg : Colors.white,
                  size: 26,
                ),
              ),
              const SizedBox(height: 8),
              Text(
                label,
                textAlign: TextAlign.center,
                style: const TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _EndCallButton extends StatelessWidget {
  final VoidCallback onTap;
  const _EndCallButton({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: Column(
        children: [
          GestureDetector(
            onTap: onTap,
            child: Container(
              width: 64,
              height: 64,
              decoration: const BoxDecoration(
                color: AppColors.callRejectRed,
                shape: BoxShape.circle,
              ),
              child: const Icon(Icons.call_end, color: Colors.white, size: 30),
            ),
          ),
          const SizedBox(height: 8),
          const Text(
            'پایان',
            style: TextStyle(color: Colors.white70, fontSize: 12),
          ),
        ],
      ),
    );
  }
}

// ── DTMF key ──────────────────────────────────────────────────────────────────

class _DtmfKey extends StatelessWidget {
  final String display;
  final VoidCallback onTap;

  const _DtmfKey({required this.display, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      shape: const CircleBorder(),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        // Round and 64 dp, so the ripple is a circle on a circle and the four
        // rows fit above «پایان» on a short screen.
        customBorder: const CircleBorder(),
        child: SizedBox(
          width: 64,
          height: 64,
          child: Center(
            child: Text(
              display,
              style: const TextStyle(color: Colors.white, fontSize: 28),
            ),
          ),
        ),
      ),
    );
  }
}
