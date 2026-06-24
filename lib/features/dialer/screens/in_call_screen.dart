import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../widgets/dialer_bottom_sheet.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';

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
  late final Timer _timer;
  int _seconds = 0;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() => _seconds++);
    });
  }

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
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
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          final onHold = state.callStatus == CallStatus.onHold;
          return Scaffold(
            backgroundColor: _kBg,
            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),
                  // Carrier / SIM line (no carrier data available → generic).
                  const Text(
                    'سیم‌کارت',
                    style: TextStyle(color: Colors.white38, fontSize: 13),
                  ),
                  const SizedBox(height: 24),
                  _buildAvatar(),
                  const SizedBox(height: 20),
                  Text(
                    widget.contactName ??
                        PersianUtils.toPersianNumber(widget.phone),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 30,
                      fontWeight: FontWeight.w300,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 10),
                  onHold
                      ? const _PulsingText('در انتظار')
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

  Widget _buildAvatar() {
    return Container(
      width: 96,
      height: 96,
      decoration: const BoxDecoration(
        color: Colors.white12,
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.person, size: 52, color: Colors.white60),
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
