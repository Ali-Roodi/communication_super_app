import 'package:flutter/material.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

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

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in const [
            ['1', '2', '3'],
            ['4', '5', '6'],
            ['7', '8', '9'],
          ]) ...[
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [for (final d in row) _key(context, d)],
            ),
            const SizedBox(height: 16),
          ],
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              const SizedBox(width: 80),
              _key(context, '0'),
              _deleteKey(context),
            ],
          ),
        ],
      ),
    );
  }

  Widget _key(BuildContext context, String digit) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: enabled ? () => onKey(digit) : null,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: theme.dividerColor),
        ),
        child: Center(
          child: Text(
            PersianUtils.toPersianNumber(digit),
            style: const TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
          ),
        ),
      ),
    );
  }

  Widget _deleteKey(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: enabled ? onDelete : null,
      borderRadius: BorderRadius.circular(40),
      child: Container(
        width: 80,
        height: 80,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(color: theme.dividerColor),
        ),
        child: const Icon(Icons.backspace, size: 24),
      ),
    );
  }
}
