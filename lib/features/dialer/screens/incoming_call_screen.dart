import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../../../core/theme/app_colors.dart';

class IncomingCallScreen extends StatelessWidget {
  final String phone;
  final String? contactName;

  const IncomingCallScreen({
    super.key,
    required this.phone,
    this.contactName,
  });

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        backgroundColor: const Color(0xFF1E1E2E),
        body: SafeArea(
          child: Column(
            children: [
              const Spacer(flex: 2),

              // ── Avatar ────────────────────────────────────────
              Container(
                width: 100,
                height: 100,
                decoration: BoxDecoration(
                  color: AppColors.googleBlue.withValues(alpha: 0.2),
                  shape: BoxShape.circle,
                  border: Border.all(color: AppColors.googleBlue, width: 2),
                ),
                child: const Icon(
                  Icons.person,
                  size: 56,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(height: 24),

              // ── Name / Number ─────────────────────────────────
              Text(
                contactName ?? phone,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 30,
                  fontWeight: FontWeight.w300,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              if (contactName != null)
                Text(
                  phone,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 16,
                  ),
                ),
              const SizedBox(height: 16),
              const Text(
                'تماس ورودی',
                style: TextStyle(color: Colors.white38, fontSize: 14),
              ),

              const Spacer(flex: 3),

              // ── Action Buttons ────────────────────────────────
              Padding(
                padding: const EdgeInsets.symmetric(
                    horizontal: 48, vertical: 40),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _CallActionButton(
                      icon: Icons.call_end,
                      color: AppColors.callRejectRed,
                      label: 'رد کردن',
                      onTap: () =>
                          context.read<DialerBloc>().add(const RejectCall()),
                    ),
                    _CallActionButton(
                      icon: Icons.call,
                      color: AppColors.callAnswerGreen,
                      label: 'پاسخ',
                      onTap: () =>
                          context.read<DialerBloc>().add(const AnswerCall()),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Reusable action button ────────────────────────────────────────────────────

class _CallActionButton extends StatelessWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onTap;

  const _CallActionButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        GestureDetector(
          onTap: onTap,
          child: Container(
            width: 72,
            height: 72,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
            ),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }
}
