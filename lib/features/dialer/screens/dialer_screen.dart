import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_widgets.dart';

// ── Main screen ───────────────────────────────────────────────────────────────

/// Dialer keypad (Section 1 spec): rounded-rectangle keys + green pill call
/// button. Hosted inside the draggable FAB bottom sheet
/// (see dialer_bottom_sheet.dart).
///
/// Built with [MainAxisSize.min] so it has an intrinsic height and can live
/// inside the scroll-driven [DraggableScrollableSheet]. The leaf widgets
/// (keypad keys, number display, action row, suggestion rows) live in
/// `widgets/dialer_widgets.dart`.
class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  // Key pill background — white in light, card surface in dark (Figma tokens).
  static const Color _keyLight = AppColors.surfaceLight;
  static const Color _keyDark = AppColors.cardDark;

  /// [Persian display, English value sent to BLoC]
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
    [
      ['*', '*'],
      ['۰', '0'],
      ['#', '#'],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          // Bottom-aligned: the flexible top area (contact suggestions, or
          // empty space) pushes the number field + keypad + actions down to
          // the bottom of the sheet, matching the native dialer.
          return Column(
            children: [
              Expanded(
                child: state.dialedNumber.isEmpty
                    ? const SizedBox.shrink()
                    : _buildSuggestions(context, state),
              ),
              DialerNumberDisplay(state: state),
              const SizedBox(height: 8),
              _buildKeypad(context),
              DialerActionRow(state: state),
            ],
          );
        },
      ),
    );
  }

  // ── Contact suggestions ───────────────────────────────────────────────────

  Widget _buildSuggestions(BuildContext context, DialerState state) {
    final theme = Theme.of(context);
    final contacts = state.matchingContacts;

    return ListView.builder(
      shrinkWrap: true,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: contacts.isEmpty ? 1 : contacts.length,
      itemBuilder: (_, i) => contacts.isNotEmpty
          ? DialerContactRow(contact: contacts[i], theme: theme)
          : DialerUnknownRow(phone: state.dialedNumber, theme: theme),
    );
  }

  // ── Keypad grid (4 rows × 3 cols) ───────────────────────────────────────────

  Widget _buildKeypad(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final keyColor = isDark ? _keyDark : _keyLight;
    final bloc = context.read<DialerBloc>();
    final tonesOn = context.read<SettingsBloc>().state.dialpadTones;

    void press(String value) {
      bloc.add(DialerNumberPressed(value));
      // Audible tone (honoring the setting) + light haptic on every key.
      if (tonesOn) NativeCallService.instance.sendDtmf(value);
      HapticFeedback.lightImpact();
    }

    // Force LTR so 1-2-3 always appear left→right (universal keypad layout).
    // A subtle shadow sits on the whole keypad container (per spec) — provided
    // by the elevation of each key's Material plus this wrapper's padding.
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _keyRows) ...[
              Row(
                children: row.map((k) {
                  final value = k[1];
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      child: DialKey(
                        display: k[0],
                        keyColor: keyColor,
                        onTap: () => press(value),
                        onLongPress: _longPressFor(context, value),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),
            ],
          ],
        ),
      ),
    );
  }

  /// Long-press behaviours: 0 → "+", 1 → voicemail (snackbar placeholder).
  VoidCallback? _longPressFor(BuildContext context, String value) {
    if (value == '0') {
      return () =>
          context.read<DialerBloc>().add(const DialerNumberPressed('+'));
    }
    if (value == '1') {
      return () => ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('در حال تماس با پست صوتی...')),
      );
    }
    return null;
  }
}
