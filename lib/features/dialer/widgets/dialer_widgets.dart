import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/highlighted_phone.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';

// ── Number display + caret + backspace ───────────────────────────────────────

/// The dialed-number readout that sits at the top of the keypad panel, with the
/// backspace tucked into the panel's leading corner — Google Phone's layout.
/// Tap deletes one digit; long-press clears the whole field.
class DialerNumberDisplay extends StatelessWidget {
  final DialerState state;
  const DialerNumberDisplay({super.key, required this.state});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final hasNumber = state.dialedNumber.isNotEmpty;
    final bloc = context.read<DialerBloc>();
    // Shrink past 11 digits so long numbers stay on one line.
    final fontSize = state.dialedNumber.length > 11 ? 28.0 : 38.0;

    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: SizedBox(
        height: 64,
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
                                  fontWeight: FontWeight.w400,
                                  letterSpacing: 1.5,
                                  color: scheme.onSurface,
                                ),
                              ),
                            ),
                            _BlinkingCaret(height: fontSize),
                          ],
                        ),
                      )
                    : const SizedBox.shrink(),
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
                  color: scheme.onSurfaceVariant,
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

// ── Dial key ─────────────────────────────────────────────────────────────────

/// A single keypad key: a wide squircle carrying the Persian digit with its
/// latin letter group underneath, exactly like Google Phone. Scales to 0.94 and
/// darkens while pressed, springing back on release.
///
/// **The key fires on touch-DOWN, through a raw [Listener], not on a tap.**
/// The keypad lives inside a draggable modal bottom sheet, so an `InkWell`'s
/// tap recognizer has to win a gesture arena against the sheet's vertical drag:
/// dialing fast means each press carries a few pixels of movement, the drag
/// recognizer claims the pointer, and the tap is never delivered — digits went
/// missing exactly when typing quickly. A [Listener] is not an arena member, so
/// its pointer callbacks always arrive, which is also how a physical keypad
/// behaves (and lets two thumbs type at once).
class DialKey extends StatefulWidget {
  /// Persian character to show.
  final String display;

  /// Letter group under the digit («ABC»…) — empty for `*`, `#`, and `1`
  /// (which carries the voicemail glyph instead).
  final String letters;

  /// Small glyph under the digit, used by `1` (voicemail) and `0` (`+`).
  final Widget? subGlyph;

  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const DialKey({
    super.key,
    required this.display,
    required this.onTap,
    this.letters = '',
    this.subGlyph,
    this.onLongPress,
  });

  @override
  State<DialKey> createState() => _DialKeyState();
}

class _DialKeyState extends State<DialKey> with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;
  bool _pressed = false;

  /// Pointer currently held on this key, so a second finger landing elsewhere
  /// never releases this key's press state.
  int? _pointer;

  /// Long-press timer started on touch-down; cancelled by the release.
  Timer? _longPress;

  /// Where the finger landed, so sliding off the key (a drag on the sheet)
  /// cancels the pending long-press instead of firing it.
  Offset _downAt = Offset.zero;

  static const Duration _kLongPress = Duration(milliseconds: 420);
  static const double _kSlop = 24;

  @override
  void initState() {
    super.initState();
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
    _longPress?.cancel();
    _ctrl.dispose();
    super.dispose();
  }

  void _setPressed(bool pressed) {
    if (_pressed != pressed) setState(() => _pressed = pressed);
    pressed ? _ctrl.forward() : _ctrl.reverse();
  }

  void _onDown(PointerDownEvent event) {
    if (_pointer != null) return; // already held by another finger
    _pointer = event.pointer;
    _downAt = event.localPosition;
    _setPressed(true);
    // The digit is typed here — see the class doc. Nothing downstream may
    // cancel it, which is the whole point.
    widget.onTap();

    final longPress = widget.onLongPress;
    _longPress?.cancel();
    if (longPress != null) {
      _longPress = Timer(_kLongPress, () {
        if (!mounted || _pointer == null) return;
        _release();
        longPress();
      });
    }
  }

  void _onMove(PointerMoveEvent event) {
    if (event.pointer != _pointer) return;
    if ((event.localPosition - _downAt).distance > _kSlop) {
      _longPress?.cancel();
      _longPress = null;
    }
  }

  void _onUp(PointerEvent event) {
    if (event.pointer != _pointer) return;
    _release();
  }

  void _release() {
    _longPress?.cancel();
    _longPress = null;
    _pointer = null;
    _setPressed(false);
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final base = scheme.keySurface;
    final pressedColor = isDark
        ? Color.alphaBlend(Colors.white.withValues(alpha: 0.10), base)
        : Color.alphaBlend(Colors.black.withValues(alpha: 0.07), base);

    return Listener(
      // Opaque: the key owns its whole rectangle, including the gaps its inner
      // padding leaves, so a slightly-off press still registers.
      behavior: HitTestBehavior.opaque,
      onPointerDown: _onDown,
      onPointerMove: _onMove,
      onPointerUp: _onUp,
      onPointerCancel: _onUp,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Material(
          color: _pressed ? pressedColor : base,
          elevation: 0,
          // Google's keys are near-stadium horizontally, softly rounded
          // vertically — a wide squircle.
          borderRadius: BorderRadius.circular(34),
          clipBehavior: Clip.antiAlias,
          child: SizedBox(
            height: 62,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.display,
                  style: TextStyle(
                    fontSize: 28,
                    fontWeight: FontWeight.w400,
                    height: 1.0,
                    color: scheme.onSurface,
                  ),
                ),
                if (widget.subGlyph != null) ...[
                  const SizedBox(height: 2),
                  widget.subGlyph!,
                ] else if (widget.letters.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    widget.letters,
                    style: TextStyle(
                      fontSize: 11,
                      letterSpacing: 1.2,
                      height: 1.0,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Green pill call button ───────────────────────────────────────────────────

/// The wide green «تماس» pill under the keypad.
class DialerCallPill extends StatelessWidget {
  final bool enabled;
  const DialerCallPill({super.key, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: AppColors.callAnswerGreen,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled
              ? () {
                  context.read<DialerBloc>().add(const MakeCall());
                  // The dialer lives in a modal bottom sheet (launched from the
                  // FAB); dismiss it so the system call UI is unobstructed.
                  Navigator.of(context).maybePop();
                }
              : null,
          child: const SizedBox(
            width: 168,
            height: 56,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(Icons.phone, color: Colors.white, size: 24),
                SizedBox(width: 10),
                Text(
                  'تماس',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 17,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Contact suggestion rows ──────────────────────────────────────────────────

/// A matched contact number shown above the keypad while a number is typed.
///
/// The row renders [PhoneMatch.number] — the number that actually matched —
/// not the contact's first number: searching for someone's second number and
/// being shown their first is the wrong answer.
class DialerContactRow extends StatelessWidget {
  final PhoneMatch match;

  const DialerContactRow({super.key, required this.match});

  ContactModel get contact => match.contact;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = match.number;

    return InkWell(
      onTap: () => Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: contact),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
        child: Row(
          children: [
            LazyContactAvatar(
              contactId: contact.id,
              name: contact.name,
              size: 44,
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 16, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Text(
                        'تلفن همراه ',
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      Directionality(
                        textDirection: TextDirection.ltr,
                        child: HighlightedPhone(
                          number: phone,
                          query: match.digits.isEmpty
                              ? ''
                              : match.digits.substring(
                                  match.matchStart < 0 ? 0 : match.matchStart,
                                  match.matchStart < 0
                                      ? 0
                                      : match.matchStart + match.matchLength,
                                ),
                          style: TextStyle(
                            fontSize: 14,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            // Direct-dial the matched contact — tapping the icon must NOT
            // open the contact page (that's the row tap).
            IconButton(
              icon: const Icon(Icons.call_outlined, size: 24),
              color: scheme.onSurfaceVariant,
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
}

/// The "not in contacts" suggestion row — tap to add the dialed number.
class DialerUnknownRow extends StatelessWidget {
  final String phone;

  const DialerUnknownRow({super.key, required this.phone});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => AddEditContactScreen(initialPhone: phone),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 10, 16, 10),
        child: Row(
          children: [
            Container(
              width: 44,
              height: 44,
              decoration: BoxDecoration(
                color: scheme.secondaryContainer,
                shape: BoxShape.circle,
              ),
              child: Icon(
                Icons.person_add_alt,
                color: scheme.onSecondaryContainer,
                size: 22,
              ),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'ایجاد مخاطب جدید',
                    style: TextStyle(fontSize: 16, color: scheme.onSurface),
                  ),
                  const SizedBox(height: 2),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      PersianUtils.displayPhone(phone),
                      style: TextStyle(
                        fontSize: 14,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
