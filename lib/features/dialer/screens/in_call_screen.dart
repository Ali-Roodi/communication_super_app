import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../bloc/dialer_state.dart';
import '../../../core/theme/app_colors.dart';

class InCallScreen extends StatefulWidget {
  final String phone;
  final String? contactName;

  const InCallScreen({
    super.key,
    required this.phone,
    this.contactName,
  });

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
    return '$m:$s';
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          return Scaffold(
            backgroundColor: const Color(0xFF1E1E2E),
            body: SafeArea(
              child: Column(
                children: [
                  const Spacer(flex: 2),

                  // ── Avatar ──────────────────────────────────────
                  Container(
                    width: 90,
                    height: 90,
                    decoration: const BoxDecoration(
                      color: Colors.white12,
                      shape: BoxShape.circle,
                    ),
                    child: const Icon(
                      Icons.person,
                      size: 50,
                      color: Colors.white60,
                    ),
                  ),
                  const SizedBox(height: 20),

                  // ── Name / Number ──────────────────────────────
                  Text(
                    widget.contactName ?? widget.phone,
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w300,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: 8),

                  // ── Timer / Status ─────────────────────────────
                  Text(
                    state.callStatus == CallStatus.onHold
                        ? 'در انتظار'
                        : _formattedTime,
                    style: const TextStyle(
                      color: Colors.white54,
                      fontSize: 16,
                    ),
                  ),

                  const Spacer(flex: 2),

                  // ── Control Buttons ────────────────────────────
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Column(
                      children: [
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ControlButton(
                              icon: state.isMuted
                                  ? Icons.mic_off
                                  : Icons.mic,
                              label: state.isMuted ? 'صدا روشن' : 'بی‌صدا',
                              active: state.isMuted,
                              onTap: () => context
                                  .read<DialerBloc>()
                                  .add(const ToggleMute()),
                            ),
                            _ControlButton(
                              icon: state.isSpeakerOn
                                  ? Icons.volume_up
                                  : Icons.volume_down,
                              label: 'بلندگو',
                              active: state.isSpeakerOn,
                              onTap: () => context
                                  .read<DialerBloc>()
                                  .add(const ToggleSpeaker()),
                            ),
                            _ControlButton(
                              icon: Icons.pause,
                              label: 'نگه دار',
                              active:
                                  state.callStatus == CallStatus.onHold,
                              onTap: () => context.read<DialerBloc>().add(
                                    HoldCall(
                                      hold: state.callStatus !=
                                          CallStatus.onHold,
                                    ),
                                  ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 48),

                        // ── End Call ─────────────────────────────
                        GestureDetector(
                          onTap: () => context
                              .read<DialerBloc>()
                              .add(const EndCall()),
                          child: Container(
                            width: 72,
                            height: 72,
                            decoration: const BoxDecoration(
                              color: AppColors.callRejectRed,
                              shape: BoxShape.circle,
                            ),
                            child: const Icon(
                              Icons.call_end,
                              color: Colors.white,
                              size: 32,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  const SizedBox(height: 48),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}

// ── Reusable control button ───────────────────────────────────────────────────

class _ControlButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool active;
  final VoidCallback onTap;

  const _ControlButton({
    required this.icon,
    required this.label,
    required this.active,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Column(
        children: [
          Container(
            width: 60,
            height: 60,
            decoration: BoxDecoration(
              color: active ? Colors.white24 : Colors.white12,
              shape: BoxShape.circle,
            ),
            child: Icon(
              icon,
              color: active ? Colors.white : Colors.white54,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            label,
            style: const TextStyle(color: Colors.white54, fontSize: 12),
          ),
        ],
      ),
    );
  }
}
