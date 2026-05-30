import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';
import '../../messages/bloc/message_bloc.dart';
import '../../messages/bloc/message_event.dart';
import '../../settings/bloc/settings_bloc.dart';

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
        body: Container(
          decoration: const BoxDecoration(
            gradient: LinearGradient(
              begin: Alignment.topCenter,
              end: Alignment.bottomCenter,
              colors: [Color(0xFF2A2A3C), Color(0xFF1C1B1F)],
            ),
          ),
          child: SafeArea(
            child: Column(
              children: [
                const Spacer(flex: 2),
                Container(
                  width: 100,
                  height: 100,
                  decoration: BoxDecoration(
                    color: AppColors.googleBlue.withValues(alpha: 0.2),
                    shape: BoxShape.circle,
                    border:
                        Border.all(color: AppColors.googleBlue, width: 2),
                  ),
                  child: const Icon(Icons.person, size: 56, color: Colors.white70),
                ),
                const SizedBox(height: 24),
                const Text('تماس ورودی',
                    style: TextStyle(color: Colors.white38, fontSize: 14)),
                const SizedBox(height: 12),
                Text(
                  contactName ?? PersianUtils.toPersianNumber(phone),
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w300,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (contactName != null) ...[
                  const SizedBox(height: 8),
                  Text(PersianUtils.toPersianNumber(phone),
                      style:
                          const TextStyle(color: Colors.white54, fontSize: 16)),
                ],
                const Spacer(flex: 3),
                // Secondary options: remind me · reply with message
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    _TextOption(
                      icon: Icons.schedule,
                      label: 'یادآوری',
                      onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('یادآوری به‌زودی فعال می‌شود')),
                      ),
                    ),
                    _TextOption(
                      icon: Icons.message_outlined,
                      label: 'پاسخ با پیام',
                      onTap: () => _showReplySheet(context),
                    ),
                  ],
                ),
                const SizedBox(height: 28),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 48),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _CallActionButton(
                        icon: Icons.call_end,
                        color: AppColors.callRejectRed,
                        label: 'رد کردن',
                        onTap: () =>
                            context.read<DialerBloc>().add(const RejectCall()),
                      ),
                      _AnswerButton(
                        onAnswer: () =>
                            context.read<DialerBloc>().add(const AnswerCall()),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 40),
              ],
            ),
          ),
        ),
      ),
    );
  }

  // ── Reply-with-message sheet ────────────────────────────────────────────────

  void _showReplySheet(BuildContext context) {
    final dialerBloc = context.read<DialerBloc>();
    final messageBloc = context.read<MessageBloc>();
    // Quick replies are user-editable in Settings → "Quick responses".
    final quickReplies = context.read<SettingsBloc>().state.quickReplies;

    void replyAndReject(String text) {
      messageBloc.add(SendMessage(phoneNumber: phone, body: text));
      dialerBloc.add(const RejectCall());
    }

    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final reply in quickReplies)
                ListTile(
                  leading: const Icon(Icons.message_outlined),
                  title: Text(reply),
                  onTap: () {
                    Navigator.of(sheetCtx).pop();
                    replyAndReject(reply);
                  },
                ),
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('نوشتن پیام...'),
                onTap: () async {
                  Navigator.of(sheetCtx).pop();
                  final custom = await _promptCustom(context);
                  if (custom != null && custom.trim().isNotEmpty) {
                    replyAndReject(custom.trim());
                  }
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<String?> _promptCustom(BuildContext context) {
    final controller = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('نوشتن پیام'),
          content: TextField(
            controller: controller,
            autofocus: true,
            maxLines: 3,
            decoration: const InputDecoration(hintText: 'پیام شما...'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(controller.text),
              child: const Text('ارسال'),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Secondary text option (remind / reply) ────────────────────────────────────

class _TextOption extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _TextOption({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: Colors.white70, size: 24),
            const SizedBox(height: 6),
            Text(label,
                style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ],
        ),
      ),
    );
  }
}

// ── Reject button ─────────────────────────────────────────────────────────────

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
            decoration: BoxDecoration(color: color, shape: BoxShape.circle),
            child: Icon(icon, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 12),
        Text(label, style: const TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}

// ── Answer button (tap or swipe up to answer) ─────────────────────────────────

class _AnswerButton extends StatefulWidget {
  final VoidCallback onAnswer;
  const _AnswerButton({required this.onAnswer});

  @override
  State<_AnswerButton> createState() => _AnswerButtonState();
}

class _AnswerButtonState extends State<_AnswerButton>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1100),
    )..repeat(reverse: true);
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Upward chevron hint that gently pulses (swipe-up to answer).
        FadeTransition(
          opacity: Tween<double>(begin: 0.3, end: 1.0).animate(_ctrl),
          child: const Icon(Icons.keyboard_arrow_up,
              color: Colors.white54, size: 22),
        ),
        GestureDetector(
          onTap: widget.onAnswer,
          onVerticalDragEnd: (d) {
            if ((d.primaryVelocity ?? 0) < -200) widget.onAnswer();
          },
          child: Container(
            width: 72,
            height: 72,
            decoration: const BoxDecoration(
              color: AppColors.callAnswerGreen,
              shape: BoxShape.circle,
            ),
            child: const Icon(Icons.call, color: Colors.white, size: 32),
          ),
        ),
        const SizedBox(height: 12),
        const Text('پاسخ',
            style: TextStyle(color: Colors.white70, fontSize: 13)),
      ],
    );
  }
}
