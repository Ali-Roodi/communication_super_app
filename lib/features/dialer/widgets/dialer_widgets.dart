import 'dart:async';
import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/call_icon_button.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/highlighted_phone.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/contacts/widgets/save_number_actions.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';

/// What the readout's long-press menu offers — Google Phone's own three.
enum _NumberMenuAction { copy, cut, paste }

/// One row of that menu: icon then label.
class _NumberMenuRow extends StatelessWidget {
  const _NumberMenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [Icon(icon, size: 18), const SizedBox(width: 12), Text(label)],
    );
  }
}

// ── Number display + caret + backspace ───────────────────────────────────────

/// The dialed-number readout that sits at the top of the keypad panel, with the
/// backspace tucked into the panel's leading corner — Google Phone's layout.
/// Tap deletes one digit; long-press clears the whole field.
///
/// **Long-pressing the readout selects the number and offers کپی / برش /
/// چسباندن**, exactly as it does in Google Phone. There the readout is an
/// `EditText`, so a long-press highlights the digits and raises the platform's
/// cut/copy/paste toolbar; this keypad has no text field for that toolbar to
/// attach to, so the highlight and the three items are drawn by hand — and the
/// highlight is not decoration: it is what says *what* the کپی is about to
/// take, and it is the state every phone user expects a long-press on text to
/// produce.
///
/// **Touching the number moves the caret** to the nearest gap between digits
/// (a tap, or a finger slid along it), and the keys and the backspace then
/// work there — a wrong second digit no longer means deleting everything after
/// it. A touch beside the number puts the caret at that end. A number too long
/// for the line is shrunk to fit rather than cut with «…», so every digit stays
/// reachable.
class DialerNumberDisplay extends StatefulWidget {
  final DialerState state;
  const DialerNumberDisplay({super.key, required this.state});

  @override
  State<DialerNumberDisplay> createState() => _DialerNumberDisplayState();
}

class _DialerNumberDisplayState extends State<DialerNumberDisplay> {
  /// True while the long-press menu is open: the digits are drawn on a
  /// selection highlight, the way selected text is.
  bool _selected = false;

  /// The digits' box, measured to turn a touch into a caret position. It sits
  /// inside a [FittedBox], and `globalToLocal` undoes that scale.
  final GlobalKey _digitsKey = GlobalKey();

  /// The digits as last laid out, for the same purpose.
  TextPainter? _painter;

  DialerState get state => widget.state;

  @override
  void dispose() {
    _painter?.dispose();
    super.dispose();
  }

  /// Puts the caret at the gap nearest [globalPosition].
  void _moveCaretTo(Offset globalPosition) {
    final box = _digitsKey.currentContext?.findRenderObject() as RenderBox?;
    final painter = _painter;
    if (box == null || painter == null || !box.hasSize) return;
    final local = box.globalToLocal(globalPosition);
    final x = local.dx.clamp(0.0, painter.width);
    final offset = painter
        .getPositionForOffset(Offset(x, painter.height / 2))
        .offset;
    if (offset == state.caret) return;
    HapticFeedback.selectionClick();
    context.read<DialerBloc>().add(DialerCaretMoved(offset));
  }

  /// The dialable part of whatever is on the clipboard, or empty.
  static Future<String> _clipboardNumber() async {
    try {
      final data = await Clipboard.getData(Clipboard.kTextPlain);
      return DialerBloc.sanitizeDialable(data?.text?.trim() ?? '');
    } catch (_) {
      return '';
    }
  }

  /// Puts [number] into the field.
  ///
  /// Appends when something is already typed (that is what paste means in the
  /// middle of a number) and replaces otherwise.
  static void _paste(BuildContext context, String number) {
    final bloc = context.read<DialerBloc>();
    HapticFeedback.mediumImpact();
    bloc.add(
      DialerNumberSet(number, append: bloc.state.dialedNumber.isNotEmpty),
    );
  }

  /// Puts the typed number on the clipboard.
  ///
  /// **ASCII digits**, never the Persian ones the readout draws: the string is
  /// going into another app's field — a browser, a note, another dialer — and
  /// «۰۹۱۲…» is not a number anywhere outside this app.
  ///
  /// No confirmation is shown: a snack bar cannot be seen from inside the modal
  /// keypad sheet (it renders behind it), and from Android 13 on the platform
  /// posts its own «Copied» chip for every clipboard write anyway.
  static void _copy(String number) {
    Clipboard.setData(ClipboardData(text: number));
    HapticFeedback.mediumImpact();
  }

  /// Selects the number and opens the کپی / برش / چسباندن menu over it.
  ///
  /// A menu rather than pasting straight away: a long-press that silently
  /// rewrites the number under the thumb is not undoable, and Google Phone asks
  /// in the same place.
  ///
  /// The digits are highlighted **for as long as the menu is up** and the
  /// highlight is dropped however the menu closes — a pick, a tap outside, the
  /// back gesture — so the selection can never be left behind on a number the
  /// user has moved on from.
  ///
  /// The clipboard is read *before* the menu is built, so an empty one shows a
  /// disabled row that says so. The alternative — a snack bar afterwards — is
  /// invisible here: the keypad lives in a modal sheet that covers the bottom
  /// of the screen, which is exactly where the snack bar appears.
  Future<void> _showNumberMenu(BuildContext context) async {
    HapticFeedback.mediumImpact();
    // Resolved before the clipboard read, so nothing looks up an ancestor
    // across the await.
    final box = context.findRenderObject() as RenderBox?;
    final overlay =
        Overlay.of(context).context.findRenderObject() as RenderBox?;
    final typed = state.dialedNumber;
    if (typed.isNotEmpty) setState(() => _selected = true);
    final number = await _clipboardNumber();
    if (!context.mounted) {
      _selected = false;
      return;
    }
    if (box == null || overlay == null || !box.hasSize) {
      setState(() => _selected = false);
      return;
    }
    final origin = box.localToGlobal(Offset.zero, ancestor: overlay);
    final picked = await showMenu<_NumberMenuAction>(
      context: context,
      position: RelativeRect.fromLTRB(
        origin.dx,
        origin.dy + box.size.height * 0.5,
        overlay.size.width - origin.dx - box.size.width,
        0,
      ),
      items: [
        // Only while something is typed: an empty field has nothing to take.
        if (typed.isNotEmpty) ...[
          const PopupMenuItem<_NumberMenuAction>(
            value: _NumberMenuAction.copy,
            child: _NumberMenuRow(icon: Icons.content_copy, label: 'کپی'),
          ),
          const PopupMenuItem<_NumberMenuAction>(
            value: _NumberMenuAction.cut,
            child: _NumberMenuRow(icon: Icons.content_cut, label: 'برش'),
          ),
        ],
        PopupMenuItem<_NumberMenuAction>(
          value: _NumberMenuAction.paste,
          enabled: number.isNotEmpty,
          child: _NumberMenuRow(
            icon: Icons.content_paste,
            label: number.isEmpty ? 'چیزی برای چسباندن نیست' : 'چسباندن',
          ),
        ),
      ],
    );
    if (mounted) setState(() => _selected = false);
    if (picked == null || !context.mounted) return;
    switch (picked) {
      case _NumberMenuAction.copy:
        _copy(typed);
      case _NumberMenuAction.cut:
        _copy(typed);
        context.read<DialerBloc>().add(const DialerNumberCleared());
      case _NumberMenuAction.paste:
        if (number.isEmpty) return;
        _paste(context, number);
    }
  }

  /// The typed number and its caret, laid out here by hand so the caret is
  /// drawn — and a touch is read — against the very same glyphs.
  Widget _digits(BuildContext context, ColorScheme scheme, double fontSize) {
    final span = TextSpan(
      text: PersianUtils.toPersianNumber(state.dialedNumber),
      style: DefaultTextStyle.of(context).style.merge(
        TextStyle(
          fontSize: fontSize,
          fontWeight: FontWeight.w400,
          letterSpacing: 1.5,
          color: scheme.onSurface,
        ),
      ),
    );
    final scaler = MediaQuery.textScalerOf(context);
    _painter?.dispose();
    final painter = _painter = TextPainter(
      text: span,
      textDirection: TextDirection.ltr,
      maxLines: 1,
      textScaler: scaler,
    )..layout();
    final caretX = painter
        .getOffsetForCaret(TextPosition(offset: state.caret), Rect.zero)
        .dx
        .clamp(0.0, painter.width);
    const caretRoom = 2.0;

    return SizedBox(
      key: _digitsKey,
      width: painter.width + caretRoom,
      height: painter.height,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            width: painter.width,
            child: DecoratedBox(
              // The selection highlight, drawn behind the digits while the
              // long-press menu is up — the platform's own selection colour,
              // so it reads as selected text and not as a chip.
              decoration: BoxDecoration(
                color: _selected
                    ? scheme.primary.withValues(alpha: 0.28)
                    : Colors.transparent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: RichText(
                text: span,
                textDirection: TextDirection.ltr,
                maxLines: 1,
                softWrap: false,
                textScaler: scaler,
              ),
            ),
          ),
          // Hidden while the number is selected: a caret and a selection are
          // two different states, and every text field drops the caret for
          // the duration of the selection. Keyed by its position so a move
          // restarts the blink visible, as a text field's caret does.
          if (!_selected)
            Positioned(
              left: caretX - 1,
              top: 0,
              bottom: 0,
              child: Center(
                child: _BlinkingCaret(
                  key: ValueKey(state.caret),
                  height: fontSize,
                ),
              ),
            ),
        ],
      ),
    );
  }

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
              // The whole readout — including the empty area before anything is
              // typed, which is where a paste most often starts — is the paste
              // target.
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onLongPress: () => _showNumberMenu(context),
                onTapUp: hasNumber
                    ? (d) => _moveCaretTo(d.globalPosition)
                    : null,
                onHorizontalDragStart: hasNumber
                    ? (d) => _moveCaretTo(d.globalPosition)
                    : null,
                onHorizontalDragUpdate: hasNumber
                    ? (d) => _moveCaretTo(d.globalPosition)
                    : null,
                child: Center(
                  child: hasNumber
                      ? FittedBox(
                          fit: BoxFit.scaleDown,
                          child: _digits(context, scheme, fontSize),
                        )
                      : const SizedBox.shrink(),
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

/// Thin blinking caret rendered where the next key goes.
class _BlinkingCaret extends StatefulWidget {
  final double height;
  const _BlinkingCaret({super.key, required this.height});

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

/// The wide green «تماس» pill under the keypad, with the SIM chip beside it
/// on a dual-SIM phone.
///
/// The chip names the card the call is about to go out on, so a dual-SIM user
/// is not surprised by it (the mentor's report). It is resolved by the very
/// rule the call is placed by ([SimService.callRoute]: the contact's card,
/// the app's default, the phone's) and follows the number as it is typed —
/// a contact with a card of their own changes it. «سیم‌کارت» on it means
/// nothing decides and the call will ask. Tapping it picks a card for this
/// call (kept until the number is cleared); long-pressing the pill picks one
/// and calls at once. While a call is up the second leg can only use that
/// call's card, so the chip names it and offers no choice.
class DialerCallPill extends StatefulWidget {
  final bool enabled;

  /// A call is already up: this dial adds a second leg («افزودن تماس»), which
  /// the label says so nobody wonders what pressing it will do to the call
  /// they are on.
  final bool addCall;

  const DialerCallPill({
    super.key,
    required this.enabled,
    this.addCall = false,
  });

  @override
  State<DialerCallPill> createState() => _DialerCallPillState();
}

class _DialerCallPillState extends State<DialerCallPill> {
  /// A card the user picked on the chip for this call.
  SimCard? _picked;

  /// What an ordinary dial of the typed number would use; null = it asks.
  SimCard? _routed;

  /// The live call's card is the only one a second leg can use.
  bool _liveCall = false;

  Timer? _resolveDebounce;

  /// Bumped per resolution, so a slow answer for an older number cannot land
  /// after the answer for the current one.
  int _resolveSeq = 0;

  @override
  void initState() {
    super.initState();
    _resolve(context.read<DialerBloc>().state.dialedNumber, immediate: true);
  }

  @override
  void dispose() {
    _resolveDebounce?.cancel();
    super.dispose();
  }

  /// Re-reads [_routed] for [number]. Debounced: it is two platform calls,
  /// and typing a number is a burst of keys.
  void _resolve(String number, {bool immediate = false}) {
    _resolveDebounce?.cancel();
    if (!SimService.isMultiSim) return;
    final seq = ++_resolveSeq;
    Future<void> run() async {
      final route = number.isEmpty
          ? null
          : await SimService.instance.callRoute(number);
      if (!mounted || seq != _resolveSeq) return;
      setState(() {
        // No number yet: the defaults alone decide. The native rule is not
        // asked — a live call aside, there is no contact to look up.
        _liveCall = route?.kind == CallRouteKind.liveCall;
        _routed = route == null
            ? SimService.defaultFor(SimUse.voice)
            : (route.asks ? null : route.sim);
      });
    }

    if (immediate || number.isEmpty) {
      unawaited(run());
    } else {
      _resolveDebounce = Timer(const Duration(milliseconds: 250), run);
    }
  }

  void _onNumberChanged(String number) {
    // A pick is for this one call: an emptied field is a new one.
    if (number.isEmpty && _picked != null) setState(() => _picked = null);
    _resolve(number);
  }

  /// Keeps the choice for the dial instead of calling at once — the chip is
  /// a choice, the pill is the action.
  Future<void> _pickSim() async {
    final number = context.read<DialerBloc>().state.dialedNumber;
    final chosen = await showSimPicker(
      context,
      title: 'تماس با کدام سیم‌کارت؟',
      subtitle: number.isEmpty ? null : number,
      selected: _picked ?? _routed,
    );
    if (chosen == null || !mounted) return;
    setState(() => _picked = chosen);
  }

  /// Hands the dial to the BLoC, asking for a SIM only when there is a real
  /// choice to make and none was picked on the chip.
  ///
  /// The picker cannot live inside `DialerBloc`: it needs a BuildContext, and
  /// a BLoC that pops UI is a BLoC that cannot be tested. The number itself
  /// stays in the BLoC, which is why the event carries only the SIM.
  Future<void> _dial(BuildContext context, {bool forcePick = false}) async {
    final bloc = context.read<DialerBloc>();
    final navigator = Navigator.of(context);
    final number = bloc.state.dialedNumber;
    if (number.isEmpty) return;

    int? subscriptionId;
    final picked = _liveCall ? null : _picked;
    if (forcePick && SimService.isMultiSim) {
      await HapticFeedback.mediumImpact();
      final route = await SimService.instance.callRoute(number);
      if (!context.mounted) return;
      final chosen = await showSimPicker(
        context,
        title: 'تماس با کدام سیم‌کارت؟',
        subtitle: number,
        selected: picked ?? route.sim,
      );
      if (chosen == null) return; // dismissed = cancelled
      subscriptionId = chosen.subscriptionId;
    } else if (picked != null &&
        SimService.byId(picked.subscriptionId) != null) {
      subscriptionId = picked.subscriptionId;
    } else {
      if (!context.mounted) return;
      final choice = await chooseVoiceSim(context, number);
      if (!choice.go) return; // dismissed = cancelled
      subscriptionId = choice.subscriptionId;
    }
    bloc.add(MakeCall(subscriptionId: subscriptionId));
    // The dialer lives in a modal bottom sheet (launched from the FAB);
    // dismiss it so the system call UI is unobstructed.
    navigator.maybePop();
  }

  Widget _pill(BuildContext context) {
    final enabled = widget.enabled;
    final addCall = widget.addCall;
    return Opacity(
      opacity: enabled ? 1.0 : 0.45,
      child: Material(
        color: AppColors.callAnswerGreen,
        borderRadius: BorderRadius.circular(28),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: enabled ? () => _dial(context) : null,
          // Long-press = "this one call, on the other card".
          onLongPress: enabled && SimService.isMultiSim && !_liveCall
              ? () => _dial(context, forcePick: true)
              : null,
          child: SizedBox(
            width: 168,
            height: 56,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(
                  addCall ? Icons.add_call : Icons.phone,
                  color: Colors.white,
                  size: 24,
                ),
                const SizedBox(width: 10),
                Text(
                  addCall ? 'افزودن تماس' : 'تماس',
                  style: const TextStyle(
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

  @override
  Widget build(BuildContext context) {
    return BlocListener<DialerBloc, DialerState>(
      listenWhen: (a, b) => a.dialedNumber != b.dialedNumber,
      listener: (_, state) => _onNumberChanged(state.dialedNumber),
      child: SimAware(
        builder: (context, _, _) {
          final pill = _pill(context);
          if (!SimService.isMultiSim) return pill;
          // The chip is drawn OUTSIDE the pill and the row is balanced with an
          // empty box of the same width, so the pill keeps its position: the
          // keypad's centre of gravity is the call button, and moving it
          // sideways on a dual-SIM phone would put it under a different thumb.
          const double kSide = 72;
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(width: kSide),
              pill,
              SizedBox(
                width: kSide,
                child: Center(
                  child: SimChip(
                    sim: _liveCall ? _routed : (_picked ?? _routed),
                    onTap: _liveCall ? null : _pickSim,
                    verb: 'تماس با',
                  ),
                ),
              ),
            ],
          );
        },
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

  /// Reached from «افزودن تماس» while a call is live: the row is a *picker*
  /// for the second leg of the conference, so tapping anywhere on it dials.
  /// Opening a contact page there is never what the user meant, and hunting
  /// for the small call icon at the edge is what made the flow feel like the
  /// button "wasn't there".
  final bool addCall;

  const DialerContactRow({
    super.key,
    required this.match,
    this.addCall = false,
  });

  ContactModel get contact => match.contact;

  /// Dials [match] and closes the keypad sheet so the in-call UI is clear.
  Future<void> _dial(BuildContext context) async {
    final navigator = Navigator.of(context);
    final called = await placeCall(context, match.number);
    if (called) navigator.maybePop();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final phone = match.number;

    return InkWell(
      onTap: addCall
          ? () => _dial(context)
          : () => Navigator.push(
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
                  // Highlighted when the row is here because the *name* was
                  // typed on the keys (T9) — without it the suggestion looks
                  // unrelated to what the user pressed.
                  _MatchedName(
                    name: contact.name,
                    start: match.nameStart,
                    length: match.nameLength,
                    style: TextStyle(fontSize: 16, color: scheme.onSurface),
                    highlight: scheme.primary,
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
            // open the contact page (that's the row tap, outside add-call
            // mode). Filled green while adding to a call: it is the primary
            // action of that screen, not a secondary affordance.
            CallIconButton(
              icon: addCall ? Icons.add_call : Icons.call_outlined,
              iconSize: 24,
              color: addCall ? Colors.white : scheme.onSurfaceVariant,
              style: addCall
                  ? IconButton.styleFrom(
                      backgroundColor: AppColors.callAnswerGreen,
                    )
                  : null,
              onPressed: () => _dial(context),
              onLongPress: SimService.isMultiSim
                  ? () async {
                      final navigator = Navigator.of(context);
                      final called = await placeCallPickingSim(context, phone);
                      // Only leave the keypad if a call was actually placed —
                      // a dismissed picker should hand the sheet back.
                      if (called) navigator.maybePop();
                    }
                  : null,
            ),
          ],
        ),
      ),
    );
  }
}

/// A contact name with the T9-matched letters emphasised.
///
/// [start]/[length] index the **original** name (see [PhoneMatch.nameStart]);
/// a range outside it is simply ignored rather than throwing — a name can change
/// underneath a match that was computed a frame earlier.
class _MatchedName extends StatelessWidget {
  final String name;
  final int start;
  final int length;
  final TextStyle style;
  final Color highlight;

  const _MatchedName({
    required this.name,
    required this.start,
    required this.length,
    required this.style,
    required this.highlight,
  });

  @override
  Widget build(BuildContext context) {
    final end = start + length;
    final valid = start >= 0 && length > 0 && end <= name.length;
    if (!valid) {
      return Text(
        name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: style,
      );
    }
    return Text.rich(
      TextSpan(
        style: style,
        children: [
          TextSpan(text: name.substring(0, start)),
          TextSpan(
            text: name.substring(start, end),
            style: TextStyle(color: highlight, fontWeight: FontWeight.w700),
          ),
          TextSpan(text: name.substring(end)),
        ],
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// What the keypad offers for the number being typed, whoever it belongs to:
/// «ایجاد مخاطب جدید» · «افزودن به مخاطب موجود» · «ارسال پیامک».
///
/// Google Phone lists all three under the suggestions from the first digit,
/// and keeps them there when a contact matches — a number that resolves to
/// somebody is still a number you may want to text, and a second number for
/// somebody already saved is the commonest reason to reach for the keypad at
/// all. This app only ever showed «ایجاد مخاطب جدید», and only while *nothing*
/// matched, so both of the other two were unreachable from here.
class DialerNumberActions extends StatelessWidget {
  final String phone;

  const DialerNumberActions({super.key, required this.phone});

  @override
  Widget build(BuildContext context) {
    return GroupedList(
      children: [
        _DialerActionRow(
          icon: Icons.person_add_alt,
          label: 'ایجاد مخاطب جدید',
          // Only the first row spells the number out: all three act on the
          // same one, and repeating it three times reads as three numbers.
          subtitle: phone,
          onTap: () => createContactWithNumber(context, phone),
        ),
        _DialerActionRow(
          icon: Icons.person_search_outlined,
          label: 'افزودن به مخاطب موجود',
          onTap: () => addNumberToExistingContact(context, phone),
        ),
        _DialerActionRow(
          icon: Icons.sms_outlined,
          label: 'ارسال پیامک',
          onTap: () => Navigator.of(context).push(
            MaterialPageRoute(
              builder: (_) => ConversationScreen.forPhone(phone),
            ),
          ),
        ),
      ],
    );
  }
}

class _DialerActionRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final String? subtitle;
  final VoidCallback onTap;

  const _DialerActionRow({
    required this.icon,
    required this.label,
    required this.onTap,
    this.subtitle,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return InkWell(
      onTap: onTap,
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
              child: Icon(icon, color: scheme.onSecondaryContainer, size: 22),
            ),
            const SizedBox(width: 14),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    label,
                    style: TextStyle(fontSize: 16, color: scheme.onSurface),
                  ),
                  if (subtitle case final s?) ...[
                    const SizedBox(height: 2),
                    Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(
                        PersianUtils.displayPhone(s),
                        style: TextStyle(
                          fontSize: 14,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
