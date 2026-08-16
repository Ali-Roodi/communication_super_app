import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/dialer_bloc.dart';
import '../bloc/dialer_event.dart';
import '../../../core/theme/app_colors.dart';
import '../../../core/utils/persian_utils.dart';
import '../../contacts/repositories/contact_repository.dart';
import '../../messages/bloc/message_bloc.dart';
import '../../messages/bloc/message_event.dart';

/// The canned answers offered by «پاسخ» when rejecting a call with an SMS.
const List<String> _kQuickReplies = [
  'الان نمی‌توانم صحبت کنم',
  'بعداً تماس می‌گیرم',
  'در راه هستم',
  'لطفاً پیام بدهید',
];

class IncomingCallScreen extends StatefulWidget {
  final String phone;
  final String? contactName;

  const IncomingCallScreen({super.key, required this.phone, this.contactName});

  @override
  State<IncomingCallScreen> createState() => _IncomingCallScreenState();
}

class _IncomingCallScreenState extends State<IncomingCallScreen> {
  String get phone => widget.phone;

  /// Resolved device-contact identity (name + photo) for the caller.
  String? _resolvedName;
  Uint8List? _avatar;

  @override
  void initState() {
    super.initState();
    _resolveContact();
  }

  /// «تماس ورودی», plus which card is ringing when there is more than one.
  ///
  /// Read straight off the bloc rather than through a builder: this screen is
  /// pushed for one call and the SIM cannot change under it, so a rebuild
  /// subscription would buy nothing.
  String _incomingLine(BuildContext context) {
    if (!SimService.isMultiSim) return 'تماس ورودی';
    final sim = SimService.byId(
      context.read<DialerBloc>().state.activeSubscriptionId,
    );
    if (sim == null) return 'تماس ورودی';
    return 'تماس ورودی · ${sim.slotLabel} · ${sim.name}';
  }

  Future<void> _resolveContact() async {
    if (phone.isEmpty) return;
    final repo = ContactRepository();
    final contact = await repo.getContactByPhoneNumber(phone);
    if (!mounted || contact == null) return;
    setState(() {
      _resolvedName = contact.name.isNotEmpty ? contact.name : null;
    });
    // Avatars are no longer held in the bulk cache — fetch this one contact's
    // thumbnail lazily by id.
    final avatar = await repo.getContactThumbnail(contact.id);
    if (!mounted || avatar == null) return;
    setState(() => _avatar = avatar);
  }

  @override
  Widget build(BuildContext context) {
    final name = widget.contactName ?? _resolvedName;
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
                    border: Border.all(color: AppColors.googleBlue, width: 2),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: _avatar != null
                      ? Image.memory(_avatar!, fit: BoxFit.cover)
                      : const Icon(
                          Icons.person,
                          size: 56,
                          color: Colors.white70,
                        ),
                ),
                const SizedBox(height: 24),
                Text(
                  // «تماس ورودی · سیم ۲ · ایرانسل» — on a dual-SIM phone the
                  // card that is ringing is the first thing worth knowing.
                  _incomingLine(context),
                  style: const TextStyle(color: Colors.white38, fontSize: 14),
                ),
                const SizedBox(height: 12),
                Text(
                  name ?? PersianUtils.displayPhone(phone),
                  // LTR so the grouped number reads 0919 096 1805, not with
                  // the groups flipped by the surrounding RTL direction.
                  textDirection: name == null ? TextDirection.ltr : null,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 30,
                    fontWeight: FontWeight.w300,
                  ),
                  textAlign: TextAlign.center,
                ),
                if (name != null) ...[
                  const SizedBox(height: 8),
                  Text(
                    PersianUtils.displayPhone(phone),
                    textDirection: TextDirection.ltr,
                    style: const TextStyle(color: Colors.white54, fontSize: 16),
                  ),
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
                        const SnackBar(
                          content: Text('یادآوری به‌زودی فعال می‌شود'),
                        ),
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
                      _CallCircleButton(
                        icon: Icons.call_end,
                        color: AppColors.callRejectRed,
                        label: 'رد کردن',
                        onPressed: () =>
                            context.read<DialerBloc>().add(const RejectCall()),
                      ),
                      _CallCircleButton(
                        icon: Icons.call,
                        color: AppColors.callAnswerGreen,
                        label: 'پاسخ',
                        swipeUp: true,
                        onPressed: () =>
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
    // A fixed list, not a setting. The editable version lived on a settings
    // page nobody reached — «نوشتن پیام...» below is the escape hatch for
    // anything these four don't say, and it is one tap away.
    const quickReplies = _kQuickReplies;

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
            Text(
              label,
              style: const TextStyle(color: Colors.white70, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Answer / reject buttons ───────────────────────────────────────────────────

/// One of the two big circles on the incoming-call screen.
///
/// It listens on the **raw pointer stream**, not through a `GestureDetector`,
/// for the same reason [DialKey] does: a tap recognizer has to win a gesture
/// arena, and the answer button used to declare a vertical drag as well (swipe
/// up to answer). A real thumb press carries a few pixels of movement, the drag
/// recognizer claimed the pointer, its velocity was nowhere near the swipe
/// threshold — and the call simply was not answered. Answering a ringing phone
/// is the one interaction in the app that must never need a second attempt.
///
/// A `Listener` is not an arena member, so its callbacks always arrive: the
/// press is confirmed on pointer-up inside the circle, and an upward swipe is
/// recognized from the pointer's own displacement.
class _CallCircleButton extends StatefulWidget {
  final IconData icon;
  final Color color;
  final String label;
  final VoidCallback onPressed;

  /// Answer-side only: an upward swipe triggers it too, and the chevron hint
  /// above the circle pulses.
  final bool swipeUp;

  const _CallCircleButton({
    required this.icon,
    required this.color,
    required this.label,
    required this.onPressed,
    this.swipeUp = false,
  });

  @override
  State<_CallCircleButton> createState() => _CallCircleButtonState();
}

class _CallCircleButtonState extends State<_CallCircleButton>
    with SingleTickerProviderStateMixin {
  static const double _kDiameter = 72;

  /// How far up the finger has to travel for the swipe to count.
  static const double _kSwipeDistance = 48;

  /// Movement still counted as "the thumb stayed put" — deliberately wider than
  /// [kTouchSlop], because a 72 dp circle pressed with a thumb wobbles.
  static const double _kTapSlop = 36;

  AnimationController? _hint;
  Offset? _downAt;
  bool _pressed = false;

  /// Answer is a one-shot: telecom will not thank us for two `answer()` calls,
  /// and a swipe that also ends in a tap-up would send exactly that.
  bool _fired = false;

  @override
  void initState() {
    super.initState();
    if (widget.swipeUp) {
      _hint =
          AnimationController(
            vsync: this,
            duration: const Duration(milliseconds: 1100),
          )..repeat(reverse: true);
    }
  }

  @override
  void dispose() {
    _hint?.dispose();
    super.dispose();
  }

  void _fire() {
    if (_fired) return;
    _fired = true;
    setState(() => _pressed = false);
    HapticFeedback.mediumImpact();
    widget.onPressed();
  }

  @override
  Widget build(BuildContext context) {
    final hint = _hint;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (hint != null)
          FadeTransition(
            opacity: Tween<double>(begin: 0.3, end: 1.0).animate(hint),
            child: const Icon(
              Icons.keyboard_arrow_up,
              color: Colors.white54,
              size: 22,
            ),
          )
        else
          const SizedBox(height: 22),
        Listener(
          onPointerDown: (event) {
            _downAt = event.position;
            _fired = false;
            setState(() => _pressed = true);
          },
          onPointerMove: (event) {
            final start = _downAt;
            if (start == null || _fired) return;
            if (widget.swipeUp && start.dy - event.position.dy >= _kSwipeDistance) {
              _fire();
              return;
            }
            // Slid off the button — treat it as a cancel, so the circle stops
            // looking pressed and the lift-off does nothing.
            if ((event.position - start).distance > _kDiameter) {
              setState(() => _pressed = false);
            }
          },
          onPointerUp: (event) {
            final start = _downAt;
            _downAt = null;
            if (start == null || _fired) return;
            if ((event.position - start).distance <= _kTapSlop) {
              _fire();
            } else {
              setState(() => _pressed = false);
            }
          },
          onPointerCancel: (_) {
            _downAt = null;
            setState(() => _pressed = false);
          },
          child: AnimatedScale(
            scale: _pressed ? 0.92 : 1,
            duration: const Duration(milliseconds: 90),
            child: Container(
              width: _kDiameter,
              height: _kDiameter,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                boxShadow: _pressed
                    ? null
                    : [
                        BoxShadow(
                          color: widget.color.withValues(alpha: 0.45),
                          blurRadius: 18,
                          spreadRadius: 1,
                        ),
                      ],
              ),
              child: Icon(widget.icon, color: Colors.white, size: 32),
            ),
          ),
        ),
        const SizedBox(height: 12),
        Text(
          widget.label,
          style: const TextStyle(color: Colors.white70, fontSize: 13),
        ),
      ],
    );
  }
}
