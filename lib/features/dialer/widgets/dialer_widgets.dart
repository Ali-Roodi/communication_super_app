import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';

// ── Number display + caret + backspace ──────────────────────────────────────────

/// The large dialed-number readout with a blinking caret and a backspace
/// button. Tap deletes one digit; long-press clears the whole field.
class DialerNumberDisplay extends StatelessWidget {
  final DialerState state;
  const DialerNumberDisplay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasNumber = state.dialedNumber.isNotEmpty;
    final bloc = context.read<DialerBloc>();
    // Shrink past 11 digits so long numbers stay on one line.
    final fontSize = state.dialedNumber.length > 11 ? 28.0 : 40.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: SizedBox(
        height: 60,
        child: Row(
          children: [
            const SizedBox(width: 48), // balances the backspace button
            Expanded(
              child: Center(
                child: hasNumber
                    ? Directionality(
                        textDirection: TextDirection.ltr,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Flexible(
                              child: Text(
                                PersianUtils.toPersianNumber(
                                  state.dialedNumber,
                                ),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                textAlign: TextAlign.center,
                                style: TextStyle(
                                  fontSize: fontSize,
                                  fontWeight: FontWeight.w300,
                                  letterSpacing: 2,
                                  color: theme.textTheme.bodyLarge?.color,
                                ),
                              ),
                            ),
                            _BlinkingCaret(height: fontSize),
                          ],
                        ),
                      )
                    : Text(
                        'شماره را وارد کنید',
                        style: TextStyle(
                          fontSize: 17,
                          color: theme.textTheme.bodyMedium?.color?.withValues(
                            alpha: 0.5,
                          ),
                        ),
                      ),
              ),
            ),
            SizedBox(
              width: 48,
              child: AnimatedOpacity(
                opacity: hasNumber ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: IconButton(
                  icon: const Icon(Icons.backspace_outlined),
                  iconSize: 24,
                  color: theme.textTheme.bodyMedium?.color,
                  tooltip: 'حذف',
                  onPressed: hasNumber
                      ? () => bloc.add(const DialerNumberDeleted())
                      : null,
                  // Long-press clears the whole field with a single vibration.
                  onLongPress: hasNumber
                      ? () {
                          HapticFeedback.mediumImpact();
                          bloc.add(const DialerNumberCleared());
                        }
                      : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Thin blinking caret rendered at the end of the typed number.
class _BlinkingCaret extends StatefulWidget {
  final double height;
  const _BlinkingCaret({required this.height});

  @override
  State<_BlinkingCaret> createState() => _BlinkingCaretState();
}

class _BlinkingCaretState extends State<_BlinkingCaret> {
  Timer? _timer;
  bool _visible = true;

  @override
  void initState() {
    super.initState();
    _timer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (mounted) setState(() => _visible = !_visible);
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedOpacity(
      opacity: _visible ? 1 : 0,
      duration: const Duration(milliseconds: 120),
      child: Container(
        width: 2,
        height: widget.height,
        margin: const EdgeInsets.only(left: 2),
        color: Theme.of(context).colorScheme.primary,
      ),
    );
  }
}

// ── Action row: add-to-contacts · call pill · delete ─────────────────────────────

/// The row beneath the keypad: add-to-contacts, the green call pill, and a
/// backspace/clear action. Collapses to a centered (disabled) call button when
/// no number has been entered.
class DialerActionRow extends StatelessWidget {
  final DialerState state;
  const DialerActionRow({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final hasNumber = state.dialedNumber.isNotEmpty;
    final canCall = hasNumber && !state.isInCall;
    final theme = Theme.of(context);

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 12, 24, 16),
        child: hasNumber
            ? Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _SideAction(
                    icon: Icons.person_add_alt_1_outlined,
                    tooltip: 'افزودن به مخاطبین',
                    onTap: () => Navigator.of(context).push(
                      MaterialPageRoute(
                        builder: (_) => AddEditContactScreen(
                          initialPhone: state.dialedNumber,
                        ),
                      ),
                    ),
                  ),
                  _CallButton(enabled: canCall),
                  _SideAction(
                    icon: Icons.backspace_outlined,
                    tooltip: 'حذف',
                    color: theme.textTheme.bodyMedium?.color,
                    onTap: () => context.read<DialerBloc>().add(
                      const DialerNumberDeleted(),
                    ),
                    onLongPress: () {
                      HapticFeedback.mediumImpact();
                      context.read<DialerBloc>().add(
                        const DialerNumberCleared(),
                      );
                    },
                  ),
                ],
              )
            : Center(child: _CallButton(enabled: false)),
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final Color? color;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _SideAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.color,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 72,
      child: Center(
        // GestureDetector adds the long-press (clear) gesture that IconButton
        // does not expose; the tap is still handled by IconButton.onPressed.
        child: GestureDetector(
          onLongPress: onLongPress,
          child: IconButton(
            icon: Icon(icon),
            iconSize: 26,
            color: color ?? theme.colorScheme.primary,
            tooltip: tooltip,
            onPressed: onTap,
          ),
        ),
      ),
    );
  }
}

// ── Animated rounded-rectangle dial key (scale 0.94 + darken on press) ───────────

/// A single keypad key. Scales to 0.94 and darkens its background while pressed,
/// springing back on release.
class DialKey extends StatefulWidget {
  final String display; // Persian character to show
  final Color keyColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const DialKey({
    super.key,
    required this.display,
    required this.keyColor,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<DialKey> createState() => _DialKeyState();
}

class _DialKeyState extends State<DialKey> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  bool _pressed = false;

  @override
  void initState() {
    super.initState();
    // Spec: scale 1.0 → 0.94 on press, spring back on release.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 90),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _scale = Tween<double>(
      begin: 1.0,
      end: 0.94,
    ).animate(CurvedAnimation(parent: _ctrl, curve: Curves.easeOut));
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    setState(() => _pressed = pressed);
    pressed ? _ctrl.forward() : _ctrl.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    // "Background darkens slightly on press."
    final pressedColor = isDark
        ? Color.alphaBlend(
            Colors.white.withValues(alpha: 0.08),
            widget.keyColor,
          )
        : Color.alphaBlend(
            Colors.black.withValues(alpha: 0.06),
            widget.keyColor,
          );

    return AnimatedBuilder(
      animation: _scale,
      builder: (_, child) => Transform.scale(scale: _scale.value, child: child),
      child: Material(
        color: _pressed ? pressedColor : widget.keyColor,
        elevation: 1,
        shadowColor: Colors.black.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          onHighlightChanged: _setPressed,
          child: SizedBox(
            // Digit-only keys, vertically centred (Figma 627:4072 — no ABC labels).
            height: 62,
            child: Center(
              child: Text(
                widget.display,
                style: TextStyle(
                  fontSize: 30,
                  fontWeight: FontWeight.w500,
                  height: 1.0,
                  color: theme.textTheme.bodyLarge?.color,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ── Green pill call button ──────────────────────────────────────────────────────

class _CallButton extends StatelessWidget {
  final bool enabled;
  const _CallButton({required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: GestureDetector(
        onTap: enabled
            ? () {
                context.read<DialerBloc>().add(const MakeCall());
                // The dialer lives in a modal bottom sheet (launched from the
                // FAB); dismiss it so the system call UI is unobstructed.
                Navigator.of(context).maybePop();
              }
            : null,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 160,
          height: 56,
          decoration: BoxDecoration(
            color: AppColors.callAnswerGreen,
            borderRadius: BorderRadius.circular(AppDimensions.radiusPill),
            boxShadow: enabled
                ? [
                    BoxShadow(
                      color: AppColors.callAnswerGreen.withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ]
                : [],
          ),
          child: const Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(Icons.phone, color: Colors.white, size: 24),
              SizedBox(width: 8),
              Text(
                'تماس',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ── Contact suggestion rows ───────────────────────────────────────────────────-

/// A matched contact shown above the keypad while a number is being typed.
class DialerContactRow extends StatelessWidget {
  final ContactModel contact;
  final ThemeData theme;

  const DialerContactRow({
    super.key,
    required this.contact,
    required this.theme,
  });

  @override
  Widget build(BuildContext context) {
    final phone = contact.phoneNumbers.isNotEmpty
        ? contact.phoneNumbers.first
        : contact.phoneNumber;

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: contact),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            _buildAvatar(),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      PersianUtils.displayPhone(phone),
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            // Direct-dial the matched contact — tapping the icon must NOT
            // open the contact page (that's the row tap).
            IconButton(
              icon: Icon(
                Icons.phone_outlined,
                size: 22,
                color: theme.colorScheme.primary,
              ),
              tooltip: 'تماس',
              onPressed: () {
                NativeCallService.instance.makeCall(phone);
                // Dialer lives in a modal sheet — dismiss it so the in-call
                // UI is unobstructed.
                Navigator.of(context).maybePop();
              },
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    return LazyContactAvatar(
      contactId: contact.id,
      name: contact.name,
      size: 44,
    );
  }
}

/// The "not in contacts" suggestion row — tap to add the dialed number.
class DialerUnknownRow extends StatelessWidget {
  final String phone;
  final ThemeData theme;

  const DialerUnknownRow({super.key, required this.phone, required this.theme});

  @override
  Widget build(BuildContext context) {
    return InkWell(
      borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddEditContactScreen(initialPhone: phone),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
        child: Row(
          children: [
            const CircleAvatar(
              radius: 22,
              backgroundColor: Color(0xFFFF9800),
              child: Icon(Icons.person, color: Colors.white, size: 22),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      PersianUtils.displayPhone(phone),
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w500,
                        color: theme.textTheme.bodyLarge?.color,
                      ),
                    ),
                  ),
                  Text(
                    'در مخاطبین نیست',
                    style: TextStyle(
                      fontSize: 13,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.person_add_outlined,
              size: 20,
              color: theme.textTheme.bodyMedium?.color,
            ),
          ],
        ),
      ),
    );
  }
}
