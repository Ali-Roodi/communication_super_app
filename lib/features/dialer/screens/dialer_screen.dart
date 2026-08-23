import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_picker_sheet.dart';
import 'package:communication_super_app/features/dialer/models/speed_dial_entry.dart';
import 'package:communication_super_app/features/dialer/services/speed_dial_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/dialer/services/voicemail.dart';
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

  /// `[Persian display, value sent to the BLoC, letter group]`
  ///
  /// The letters are **Persian**, and they are the same table T9 matches on
  /// (`SearchText._t9Groups`): a keypad that finds «کبری» under ۷۲۴ has to say
  /// so on the keys, or the feature is invisible. Latin names are still found —
  /// the keys just don't have room to print both alphabets.
  static const List<List<List<String>>> _keyRows = [
    [
      ['۱', '1', ''],
      ['۲', '2', 'ا ب پ ت ث'],
      ['۳', '3', 'ج چ ح خ'],
    ],
    [
      ['۴', '4', 'د ذ ر ز ژ'],
      ['۵', '5', 'س ش ص ض'],
      ['۶', '6', 'ط ظ ع غ'],
    ],
    [
      ['۷', '7', 'ف ق ک گ'],
      ['۸', '8', 'ل م ن و'],
      ['۹', '9', 'ه ی'],
    ],
    [
      ['*', '*', ''],
      ['۰', '0', ''],
      ['#', '#', ''],
    ],
  ];

  @override
  Widget build(BuildContext context) {
    // Deliberately NOT one BlocBuilder around the whole screen: every keypress
    // emits a new state, and rebuilding the 12 keys (each an animating stateful
    // widget) plus the suggestion list on every digit is main-thread work
    // between the finger going down and the next one. Only the parts that
    // actually depend on the state rebuild; the key grid is built once.
    return const Directionality(
      textDirection: TextDirection.rtl,
      child: Column(
        children: [
          Expanded(child: _Suggestions()),
          _KeypadPanel(keyRows: _keyRows),
        ],
      ),
    );
  }
}

// ── Contact suggestions ──────────────────────────────────────────────────────

class _Suggestions extends StatelessWidget {
  const _Suggestions();

  @override
  Widget build(BuildContext context) {
    return BlocBuilder<DialerBloc, DialerState>(
      // Only the dialled number and the resolved matches change what is drawn
      // here — the call-state fields of DialerState do not, except `isInCall`:
      // the keypad reached through «افزودن تماس» is picking the second leg of
      // a conference, and a row there dials instead of opening a contact page.
      buildWhen: (a, b) =>
          a.dialedNumber != b.dialedNumber ||
          a.isInCall != b.isInCall ||
          !identical(a.matchingNumbers, b.matchingNumbers),
      builder: (context, state) => state.dialedNumber.isEmpty || _isCode(state)
          ? const SizedBox.shrink()
          : _SuggestionList(state: state),
    );
  }

  /// A service code being typed («*100#», «*140*11#») is not a person: no
  /// contact number carries `*` or `#`, so the only row left would be «ایجاد
  /// مخاطب جدید» offering to save a USSD code to the address book.
  static bool _isCode(DialerState state) =>
      state.dialedNumber.contains('*') || state.dialedNumber.contains('#');
}

class _SuggestionList extends StatelessWidget {
  final DialerState state;
  const _SuggestionList({required this.state});

  @override
  Widget build(BuildContext context) {
    final matches = state.matchingNumbers;
    // «افزودن تماس» — a call is already up, so this keypad exists to pick the
    // person to add. The whole row dials in that mode (a contact page is not
    // what anyone is after mid-call) and «ایجاد مخاطب جدید» is dropped.
    final addCall = state.isInCall;
    // Virtualized: a single typed digit can match the whole address book, and
    // an eager list would build (and avatar-fetch) every one of those rows.
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: SectionLabel(
            addCall ? 'افزودن به تماس' : 'پیشنهادی',
            padding: const EdgeInsets.fromLTRB(24, 8, 24, 8),
          ),
        ),
        if (matches.isNotEmpty)
          SliverGroupedList(
            itemCount: matches.length,
            itemBuilder: (_, i) =>
                DialerContactRow(match: matches[i], addCall: addCall),
          ),
        // What can be done with the number itself — always, and whether or not
        // a contact matched, exactly as Google Phone lists them. Dropped only
        // in «افزودن تماس» mode, where this keypad is picking the second leg
        // of a conference and nothing else.
        if (!addCall) ...[
          if (matches.isNotEmpty)
            const SliverToBoxAdapter(child: SizedBox(height: 8)),
          SliverToBoxAdapter(
            child: DialerNumberActions(phone: state.dialedNumber),
          ),
        ],
        const SliverToBoxAdapter(child: SizedBox(height: 8)),
      ],
    );
  }
}

// ── Keypad panel ─────────────────────────────────────────────────────────────

/// The raised panel holding the number readout, the key grid and the call pill.
class _KeypadPanel extends StatelessWidget {
  final List<List<List<String>>> keyRows;

  const _KeypadPanel({required this.keyRows});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;

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
            BlocBuilder<DialerBloc, DialerState>(
              buildWhen: (a, b) => a.dialedNumber != b.dialedNumber,
              builder: (_, state) => DialerNumberDisplay(state: state),
            ),
            const SizedBox(height: 4),
            // Outside every builder: the keys never depend on the state, and
            // rebuilding them mid-dial is what the touch fix is about.
            _KeyGrid(keyRows: keyRows),
            const SizedBox(height: 14),
            BlocBuilder<DialerBloc, DialerState>(
              buildWhen: (a, b) =>
                  a.dialedNumber.isEmpty != b.dialedNumber.isEmpty ||
                  a.isInCall != b.isInCall,
              // A live call must NOT disable the pill. This keypad is reached
              // from «افزودن تماس» precisely to place a second call — telecom
              // holds the first one and the two can then be merged. Gating on
              // `isInCall` left the only green button on the screen greyed out
              // with no way to add anyone.
              builder: (_, state) => DialerCallPill(
                enabled: state.dialedNumber.isNotEmpty,
                addCall: state.isInCall,
              ),
            ),
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
    final settings = context.read<SettingsBloc>();

    void press(String value) {
      bloc.add(DialerNumberPressed(value));
      // Audible tone (honoring the setting, read per press so toggling it in
      // settings takes effect without rebuilding the grid) + light haptic.
      //
      // playKeypadTone, NOT sendDtmf: this keypad is also the «افزودن تماس»
      // one, and sendDtmf transmits the digit to whoever is already on the
      // call.
      if (settings.state.dialpadTones) {
        NativeCallService.instance.playKeypadTone(value);
      }
      if (settings.state.dialpadHaptics) {
        HapticFeedback.lightImpact();
      }
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

  /// Long-press behaviours: 0 → «+», 1 → voicemail, 2–9 → speed dial.
  ///
  /// The key already typed its digit on touch-down (see [DialKey]), so each of
  /// these first deletes that digit — otherwise holding `0` would leave «۰+».
  VoidCallback? _longPressFor(BuildContext context, String value) {
    if (value == '0') {
      return () {
        HapticFeedback.mediumImpact();
        context.read<DialerBloc>()
          ..add(const DialerNumberDeleted())
          ..add(const DialerNumberPressed('+'));
      };
    }
    if (value == '1') {
      return () {
        HapticFeedback.mediumImpact();
        context.read<DialerBloc>().add(const DialerNumberDeleted());
        _callVoicemail(context);
      };
    }
    final position = int.tryParse(value);
    if (position != null && SpeedDialEntry.isAssignable(position)) {
      return () => _speedDial(context, position);
    }
    return null;
  }

  /// Holding ۲–۹ calls that key's contact, or offers to put one there.
  ///
  /// **Only from an empty field.** The digit that was just typed is the first
  /// one, or the user is in the middle of dialling a number and holding a key
  /// is not a request to call someone else — Google Phone draws the line in
  /// exactly the same place.
  Future<void> _speedDial(BuildContext context, int position) async {
    final bloc = context.read<DialerBloc>();
    if (bloc.state.dialedNumber.length != 1) return;

    HapticFeedback.mediumImpact();
    bloc.add(const DialerNumberDeleted());

    final entry = await SpeedDialService.instance.entryFor(position);
    if (!context.mounted) return;
    if (entry == null) {
      await _offerAssign(context, position);
      return;
    }
    final navigator = Navigator.of(context);
    // The keypad lives in a modal sheet — leave it only once a call was
    // actually placed, so a dismissed SIM picker hands it back.
    if (await placeCall(context, entry.phoneNumber)) navigator.maybePop();
  }

  /// An unassigned key: ask, rather than doing nothing. A long-press that
  /// silently does nothing reads as a broken keypad.
  Future<void> _offerAssign(BuildContext context, int position) async {
    final digit = PersianUtils.toPersianNumber('$position');
    final assign = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: Text('کلید $digit خالی است'),
          content: Text(
            'می‌خواهید مخاطبی را روی کلید $digit بگذارید تا با نگه‌داشتن آن تماس گرفته شود؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('نه'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('انتخاب مخاطب'),
            ),
          ],
        ),
      ),
    );
    if (assign != true || !context.mounted) return;
    final picked = await showContactPickerSheet(
      context,
      title: 'مخاطب کلید $digit',
    );
    if (picked == null) return;
    await SpeedDialService.instance.assign(
      position: position,
      phoneNumber: picked.number,
      name: picked.contact.name,
      contactId: picked.contact.id,
    );
    if (!context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text('${picked.contact.name} روی کلید $digit تنظیم شد'),
      ),
    );
  }

  /// Dials the SIM's voicemail. The whole interaction (SIM choice, the
  /// "no mailbox provisioned" case) lives in [callVoicemail] — the recents menu
  /// offers the same thing and the two must not drift.
  Future<void> _callVoicemail(BuildContext context) async {
    final navigator = Navigator.of(context);
    // The dialer lives in a modal sheet — dismiss it, but only once a call was
    // actually placed, so a dismissed SIM picker hands the keypad back.
    if (await callVoicemail(context)) navigator.maybePop();
  }
}
