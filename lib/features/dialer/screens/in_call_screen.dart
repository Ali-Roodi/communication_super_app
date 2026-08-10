import 'dart:async';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../widgets/dialer_bottom_sheet.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';
import '../../contacts/repositories/contact_repository.dart';

const Color _kBg = Color(0xFF1C1B1F);
const Color _kActiveTint = AppColors.googleBlueDark; // #8AB4F8

class InCallScreen extends StatefulWidget {
  final String phone;
  final String? contactName;

  const InCallScreen({super.key, required this.phone, this.contactName});

  @override
  State<InCallScreen> createState() => _InCallScreenState();
}

class _InCallScreenState extends State<InCallScreen> {
  Timer? _timer;
  int _seconds = 0;

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

  /// The duration counts talk time only: it starts on the first ACTIVE state,
  /// not when the screen mounts (which happens while the call is still
  /// dialing/ringing).
  void _ensureTimerStarted() {
    _timer ??= Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  /// The carrier line under the top of the call screen.
  ///
  /// Falls back to the generic word whenever there is nothing to disambiguate:
  /// a single-SIM phone, a VoIP call, or a card the roster cannot name.
  String _simLine(DialerState state) {
    if (!SimService.isMultiSim) return 'سیم‌کارت';
    final sim = SimService.byId(state.activeSubscriptionId);
    if (sim == null) return 'سیم‌کارت';
    return '${sim.slotLabel} · ${sim.name}';
  }

  String get _formattedTime {
    final m = (_seconds ~/ 60).toString().padLeft(2, '0');
    final s = (_seconds % 60).toString().padLeft(2, '0');
    return PersianUtils.toPersianNumber('$m:$s');
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocConsumer<DialerBloc, DialerState>(
        listenWhen: (prev, curr) =>
            prev.callStatus != curr.callStatus ||
            prev.activePhone != curr.activePhone,
        listener: (context, state) {
          if (state.callStatus == CallStatus.active) _ensureTimerStarted();
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
          final name = conference
              ? 'تماس گروهی'
              : (passedName ?? _resolvedName);
          return Scaffold(
            backgroundColor: _kBg,
            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // The SIM this call is on — Google Phone's carrier line.
                  // On a single-SIM phone it stays the generic word (there is
                  // nothing to disambiguate); on a dual-SIM one it names the
                  // slot and the carrier, which is the whole point of the line.
                  Text(
                    _simLine(state),
                    style: const TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
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
                      style: const TextStyle(
                        color: Colors.white54,
                        fontSize: 15,
                      ),
                    ),
                  ],
                  const SizedBox(height: 10),
                  onHold
                      ? const _PulsingText('در انتظار')
                      : dialing
                      ? const _PulsingText('در حال برقراری تماس…')
                      : Text(
                          _formattedTime,
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
      ),
    );
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
                onTap: () => _showDtmfPad(context),
              ),
              _ControlButton(
                icon: state.isSpeakerOn ? Icons.volume_up : Icons.volume_down,
                label: 'بلندگو',
                active: state.isSpeakerOn,
                onTap: () => bloc.add(const ToggleSpeaker()),
                onLongPress: () => _showAudioPicker(context, state),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Second call in progress: conference controls (ادغام / تعویض).
          if (state.callCount > 1) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                _ControlButton(
                  icon: Icons.call_merge,
                  label: 'ادغام تماس',
                  active: false,
                  onTap: state.canMerge
                      ? () => bloc.add(const MergeCalls())
                      : () => ScaffoldMessenger.of(context).showSnackBar(
                          const SnackBar(
                            content: Text('ادغام تماس در دسترس نیست'),
                          ),
                        ),
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
              _ControlButton(
                icon: Icons.add_call,
                label: 'افزودن تماس',
                active: false,
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

  // ── DTMF keypad overlay ─────────────────────────────────────────────────────

  void _showDtmfPad(BuildContext context) {
    final bloc = context.read<DialerBloc>();
    final entered = StringBuffer();

    showModalBottomSheet<void>(
      context: context,
      backgroundColor: _kBg,
      isScrollControlled: true,
      builder: (_) => StatefulBuilder(
        builder: (ctx, setSheetState) {
          return Directionality(
            textDirection: TextDirection.ltr,
            child: SafeArea(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 24),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    SizedBox(
                      height: 40,
                      child: Center(
                        child: Text(
                          PersianUtils.toPersianNumber(entered.toString()),
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 28,
                            letterSpacing: 2,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    for (final row in _dtmfRows)
                      Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: row.map((k) {
                          return _DtmfKey(
                            display: k[0],
                            onTap: () {
                              bloc.add(SendDtmf(k[1]));
                              setSheetState(() => entered.write(k[1]));
                            },
                          );
                        }).toList(),
                      ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => Navigator.of(ctx).pop(),
                        child: const Text('بستن'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        },
      ),
    );
  }

  // ── Audio output picker (speaker long-press) ─────────────────────────────────

  void _showAudioPicker(BuildContext context, DialerState state) {
    final bloc = context.read<DialerBloc>();
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.phone_in_talk),
                title: const Text('گوشی'),
                trailing: state.isSpeakerOn
                    ? null
                    : const Icon(Icons.check, color: AppColors.callAnswerGreen),
                onTap: () {
                  if (state.isSpeakerOn) bloc.add(const ToggleSpeaker());
                  Navigator.of(sheetCtx).pop();
                },
              ),
              ListTile(
                leading: const Icon(Icons.volume_up),
                title: const Text('بلندگو'),
                trailing: state.isSpeakerOn
                    ? const Icon(Icons.check, color: AppColors.callAnswerGreen)
                    : null,
                onTap: () {
                  if (!state.isSpeakerOn) bloc.add(const ToggleSpeaker());
                  Navigator.of(sheetCtx).pop();
                },
              ),
              ListTile(
                leading: const Icon(Icons.bluetooth),
                title: const Text('بلوتوث'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('دستگاه بلوتوثی یافت نشد')),
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

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
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 84,
      child: GestureDetector(
        onTap: onTap,
        onLongPress: onLongPress,
        child: Column(
          children: [
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: active ? _kActiveTint : Colors.white12,
                shape: BoxShape.circle,
              ),
              child: Icon(icon, color: active ? _kBg : Colors.white, size: 26),
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
        child: SizedBox(
          width: 64,
          height: 56,
          child: Center(
            child: Text(
              display,
              style: const TextStyle(color: Colors.white, fontSize: 26),
            ),
          ),
        ),
      ),
    );
  }
}
