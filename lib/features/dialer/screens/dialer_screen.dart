import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_widgets.dart';

// ── Main screen ──────────────────────────────────────────────────────────────

/// The keypad, laid out like Google Phone's «صفحه‌کلید» tab: matched contacts
/// float at the top under a «پیشنهادی» label, and the keypad itself lives on a
/// raised rounded panel pinned to the bottom carrying the number readout, the
/// key grid and the green «تماس» pill.
///
/// Hosted inside the draggable FAB bottom sheet (dialer_bottom_sheet.dart); the
/// leaf widgets live in `widgets/dialer_widgets.dart`.
class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  /// `[Persian display, value sent to the BLoC, latin letter group]`
  static const List<List<List<String>>> _keyRows = [
    [
      ['۱', '1', ''],
      ['۲', '2', 'ABC'],
      ['۳', '3', 'DEF'],
    ],
    [
      ['۴', '4', 'GHI'],
      ['۵', '5', 'JKL'],
      ['۶', '6', 'MNO'],
    ],
    [
      ['۷', '7', 'PQRS'],
      ['۸', '8', 'TUV'],
      ['۹', '9', 'WXYZ'],
    ],
    [
      ['*', '*', ''],
      ['۰', '0', ''],
      ['#', '#', ''],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          return Column(
            children: [
              Expanded(
                child: state.dialedNumber.isEmpty
                    ? const SizedBox.shrink()
                    : _Suggestions(state: state),
              ),
              _KeypadPanel(state: state, keyRows: _keyRows),
            ],
          );
        },
      ),
    );
  }
}

// ── Contact suggestions ──────────────────────────────────────────────────────

class _Suggestions extends StatelessWidget {
  final DialerState state;
  const _Suggestions({required this.state});

  @override
  Widget build(BuildContext context) {
    final matches = state.matchingNumbers;
    // Virtualized: a single typed digit can match the whole address book, and
    // an eager list would build (and avatar-fetch) every one of those rows.
    return CustomScrollView(
      slivers: [
        const SliverToBoxAdapter(
          child: SectionLabel(
            'پیشنهادی',
            padding: EdgeInsets.fromLTRB(24, 8, 24, 8),
          ),
        ),
        if (matches.isEmpty)
          SliverToBoxAdapter(
            child: GroupedList(
              children: [DialerUnknownRow(phone: state.dialedNumber)],
            ),
          )
        else
          SliverGroupedList(
            itemCount: matches.length,
            itemBuilder: (_, i) => DialerContactRow(match: matches[i]),
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }
}

// ── Keypad panel ─────────────────────────────────────────────────────────────

/// The raised panel holding the number readout, the key grid and the call pill.
class _KeypadPanel extends StatelessWidget {
  final DialerState state;
  final List<List<List<String>>> keyRows;

  const _KeypadPanel({required this.state, required this.keyRows});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final canCall = state.dialedNumber.isNotEmpty && !state.isInCall;

    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        color: scheme.raisedSurface,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(28)),
      ),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            DialerNumberDisplay(state: state),
            const SizedBox(height: 4),
            _KeyGrid(keyRows: keyRows),
            const SizedBox(height: 14),
            DialerCallPill(enabled: canCall),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}

class _KeyGrid extends StatelessWidget {
  final List<List<List<String>>> keyRows;
  const _KeyGrid({required this.keyRows});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final bloc = context.read<DialerBloc>();
    final tonesOn = context.read<SettingsBloc>().state.dialpadTones;

    void press(String value) {
      bloc.add(DialerNumberPressed(value));
      // Audible tone (honoring the setting) + light haptic on every key.
      if (tonesOn) NativeCallService.instance.sendDtmf(value);
      HapticFeedback.lightImpact();
    }

    // Force LTR so 1-2-3 always appear left→right (universal keypad layout).
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in keyRows) ...[
              Row(
                children: row.map((k) {
                  final value = k[1];
                  return Expanded(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 5,
                        vertical: 5,
                      ),
                      child: DialKey(
                        display: k[0],
                        letters: k[2],
                        subGlyph: _subGlyphFor(value, scheme),
                        onTap: () => press(value),
                        onLongPress: _longPressFor(context, value),
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// `1` carries the voicemail glyph and `0` the `+` it types on long-press —
  /// the two keys Google labels with a symbol instead of letters.
  Widget? _subGlyphFor(String value, ColorScheme scheme) {
    if (value == '1') {
      return Icon(Icons.voicemail, size: 13, color: scheme.onSurfaceVariant);
    }
    if (value == '0') {
      return Text(
        '+',
        style: TextStyle(
          fontSize: 13,
          height: 1.0,
          color: scheme.onSurfaceVariant,
        ),
      );
    }
    return null;
  }

  /// Long-press behaviours: 0 → «+», 1 → voicemail.
  VoidCallback? _longPressFor(BuildContext context, String value) {
    if (value == '0') {
      return () =>
          context.read<DialerBloc>().add(const DialerNumberPressed('+'));
    }
    if (value == '1') return () => _callVoicemail(context);
    return null;
  }

  /// Dials the SIM's voicemail number. Carriers that never provisioned one
  /// (common on Iranian SIMs) report null — say so rather than dialing a guess.
  Future<void> _callVoicemail(BuildContext context) async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    final number = await NativeCallService.instance.getVoicemailNumber();
    if (number == null || number.isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('شماره پست صوتی روی سیم‌کارت تنظیم نشده')),
      );
      return;
    }
    NativeCallService.instance.makeCall(number);
    // The dialer lives in a modal sheet — dismiss it so the call UI is clear.
    navigator.maybePop();
  }
}
