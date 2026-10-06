import 'package:flutter/material.dart';

/// A call icon whose long-press asks which SIM — the override every call
/// button in the app carries (`placeCallPickingSim`).
///
/// It is NOT an `IconButton` with a `tooltip` inside a `GestureDetector`,
/// which is what each call site used to be. On a touch screen a tooltip
/// opens on long-press through its own recogniser, which sits deeper in the
/// tree than the detector and so wins the gesture arena: holding the button
/// showed «تماس · نگه‌داشتن برای انتخاب سیم‌کارت» and never the picker. The
/// same words travel as the semantics label instead, which a screen reader
/// reads the same way, and the long-press reaches [onLongPress].
class CallIconButton extends StatelessWidget {
  const CallIconButton({
    super.key,
    required this.onPressed,
    this.onLongPress,
    this.icon = Icons.call_outlined,
    this.color,
    this.style,
    this.iconSize,
  });

  final VoidCallback onPressed;

  /// Null on a single-SIM phone, where there is no card to choose.
  final VoidCallback? onLongPress;

  final IconData icon;
  final Color? color;
  final ButtonStyle? style;
  final double? iconSize;

  @override
  Widget build(BuildContext context) {
    final picks = onLongPress != null;
    return Semantics(
      button: true,
      label: picks ? 'تماس · نگه‌داشتن برای انتخاب سیم‌کارت' : 'تماس',
      onLongPressHint: picks ? 'انتخاب سیم‌کارت' : null,
      child: GestureDetector(
        onLongPress: onLongPress,
        child: IconButton(
          icon: Icon(icon),
          iconSize: iconSize,
          color: color,
          style: style,
          onPressed: onPressed,
        ),
      ),
    );
  }
}
