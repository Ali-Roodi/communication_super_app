import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_widgets.dart'
    show DialKey;

/// Row of 4 PIN dots that fill (in the primary colour) as digits are entered.
class PinDots extends StatelessWidget {
  final int length;
  final int filled;

  const PinDots({super.key, this.length = 4, required this.filled});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(length, (i) {
        return Container(
          margin: const EdgeInsets.symmetric(horizontal: 8),
          width: 20,
          height: 20,
          decoration: BoxDecoration(
            shape: BoxShape.circle,
            border: Border.all(color: theme.colorScheme.outline),
            color: i < filled ? theme.colorScheme.primary : Colors.transparent,
          ),
        );
      }),
    );
  }
}

/// Shared numeric keypad for the PIN screens. Shows Persian digits but reports
/// the Latin digit value to [onKey], so PIN comparison logic stays ASCII.
///
/// Visually identical to the dialer keypad: the same [DialKey] pill keys
/// (rounded rect, press-scale animation, elevation), the same colors, and the
/// same forced-LTR 1-2-3 row order — one keypad language across the app.
class PinKeypad extends StatelessWidget {
  final void Function(String digit) onKey;
  final VoidCallback onDelete;
  final bool enabled;

  const PinKeypad({
    super.key,
    required this.onKey,
    required this.onDelete,
    this.enabled = true,
  });

  /// [Persian display, Latin value] — mirrors the dialer's `_keyRows`.
  static const List<List<List<String>>> _keyRows = [
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
  ];

  @override
  Widget build(BuildContext context) {
    void press(String value) {
      if (!enabled) return;
      HapticFeedback.lightImpact();
      onKey(value);
    }

    Widget cell(Widget child) => Expanded(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6),
        child: child,
      ),
    );

    // Force LTR so 1-2-3 always appear left→right, exactly like the dialer.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _keyRows) ...[
              Row(
                children: [
                  for (final k in row)
                    cell(DialKey(display: k[0], onTap: () => press(k[1]))),
                ],
              ),
              const SizedBox(height: 12),
            ],
            Row(
              children: [
                // Empty slot keeps 0 centred (dialer has * here; PIN doesn't).
                cell(const SizedBox(height: 62)),
                cell(DialKey(display: '۰', onTap: () => press('0'))),
                cell(_BackspaceKey(enabled: enabled, onDelete: onDelete)),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Backspace key styled like a [DialKey] pill (icon instead of a digit).
class _BackspaceKey extends StatelessWidget {
  final bool enabled;
  final VoidCallback onDelete;

  const _BackspaceKey({required this.enabled, required this.onDelete});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.keySurface,
      borderRadius: BorderRadius.circular(34),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: enabled
            ? () {
                HapticFeedback.lightImpact();
                onDelete();
              }
            : null,
        child: SizedBox(
          height: 62,
          child: Icon(
            Icons.backspace_outlined,
            size: 24,
            color: scheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}
