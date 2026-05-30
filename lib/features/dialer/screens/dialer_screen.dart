import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';

// ── Main screen ───────────────────────────────────────────────────────────────

/// Google Phone style dialer. Hosted inside the FAB bottom sheet
/// (see dialer_bottom_sheet.dart). Layout, top → bottom:
///   number display (+ backspace) · contact suggestions · keypad · action row.
class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  /// Sub-labels shown below each dial key (standard phone keypad layout).
  static const Map<String, String> _keySubLabels = {
    '1': '',    '2': 'ABC',  '3': 'DEF',
    '4': 'GHI', '5': 'JKL',  '6': 'MNO',
    '7': 'PQRS','8': 'TUV',  '9': 'WXYZ',
    '*': '',    '0': '+',    '#': '',
  };

  /// [Persian display, English value sent to BLoC]
  static const List<List<List<String>>> _keyRows = [
    [['۱', '1'], ['۲', '2'], ['۳', '3']],
    [['۴', '4'], ['۵', '5'], ['۶', '6']],
    [['۷', '7'], ['۸', '8'], ['۹', '9']],
    [['*',  '*'], ['۰', '0'], ['#',  '#']],
  ];

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          return Column(
            children: [
              _NumberDisplay(state: state),
              // Suggestions fill the gap between the number field and keypad.
              Expanded(
                child: state.dialedNumber.isEmpty
                    ? const SizedBox.shrink()
                    : _buildSuggestions(context, state),
              ),
              _buildKeypad(context),
              _ActionRow(state: state),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      itemCount: contacts.isEmpty ? 1 : contacts.length,
      itemBuilder: (_, i) => contacts.isNotEmpty
          ? _ContactRow(contact: contacts[i], theme: theme)
          : _UnknownRow(phone: state.dialedNumber, theme: theme),
    );
  }

  // ── Keypad grid (4 rows × 3 cols) ───────────────────────────────────────────

  Widget _buildKeypad(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final keyColor = isDark ? AppColors.keypadDark : AppColors.keypadLight;
    final bloc = context.read<DialerBloc>();
    final tonesOn = context.read<SettingsBloc>().state.dialpadTones;

    void press(String value) {
      bloc.add(DialerNumberPressed(value));
      // Audible + haptic feedback, honoring the "Dialpad tones" setting.
      if (tonesOn) NativeCallService.instance.sendDtmf(value);
      HapticFeedback.selectionClick();
    }

    // Force LTR so 1-2-3 always appear left→right (universal keypad layout).
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final row in _keyRows) ...[
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: row.map((k) {
                  final value = k[1];
                  return _DialKey(
                    display: k[0],
                    subLabel: _keySubLabels[value] ?? '',
                    keyColor: keyColor,
                    onTap: () => press(value),
                    onLongPress: _longPressFor(context, value),
                  );
                }).toList(),
              ),
              const SizedBox(height: 10),
            ],
          ],
        ),
      ),
    );
  }

  /// Long-press behaviours: 0 → "+", 1 → voicemail (snackbar placeholder).
  VoidCallback? _longPressFor(BuildContext context, String value) {
    if (value == '0') {
      return () => context.read<DialerBloc>().add(const DialerNumberPressed('+'));
    }
    if (value == '1') {
      return () => ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('پست صوتی')),
          );
    }
    return null;
  }
}

// ── Number display + backspace ────────────────────────────────────────────────

class _NumberDisplay extends StatelessWidget {
  final DialerState state;
  const _NumberDisplay({required this.state});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final hasNumber = state.dialedNumber.isNotEmpty;
    final bloc = context.read<DialerBloc>();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: SizedBox(
        height: 56,
        child: Row(
          children: [
            const SizedBox(width: 48), // balances the backspace button
            Expanded(
              child: Center(
                child: hasNumber
                    ? Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          PersianUtils.toPersianNumber(state.dialedNumber),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            fontSize: 36,
                            fontWeight: FontWeight.w300,
                            letterSpacing: 2,
                            color: theme.textTheme.bodyLarge?.color,
                          ),
                        ),
                      )
                    : Text(
                        'شماره را وارد کنید',
                        style: TextStyle(
                          fontSize: 17,
                          color: theme.textTheme.bodyMedium?.color
                              ?.withValues(alpha: 0.5),
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
                  // Long-press clears the whole field.
                  onLongPress:
                      hasNumber ? () => bloc.add(const DialerNumberCleared()) : null,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ── Action row: add-to-contacts · call FAB · video ────────────────────────────

class _ActionRow extends StatelessWidget {
  final DialerState state;
  const _ActionRow({required this.state});

  @override
  Widget build(BuildContext context) {
    final hasNumber = state.dialedNumber.isNotEmpty;
    final canCall = hasNumber && !state.isInCall;

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
                        builder: (_) =>
                            AddEditContactScreen(initialPhone: state.dialedNumber),
                      ),
                    ),
                  ),
                  _CallButton(enabled: canCall),
                  _SideAction(
                    icon: Icons.videocam_outlined,
                    tooltip: 'تماس تصویری',
                    onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('تماس تصویری پشتیبانی نمی‌شود'),
                      ),
                    ),
                  ),
                ],
              )
            : Center(
                child: _CallButton(enabled: false),
              ),
      ),
    );
  }
}

class _SideAction extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  const _SideAction({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return SizedBox(
      width: 72,
      child: Center(
        child: IconButton(
          icon: Icon(icon),
          iconSize: 26,
          color: theme.colorScheme.primary,
          tooltip: tooltip,
          onPressed: onTap,
        ),
      ),
    );
  }
}

// ── Animated dial key (scale + ripple) ─────────────────────────────────────────

class _DialKey extends StatefulWidget {
  final String display;   // Persian character to show
  final String subLabel;  // Letters under the digit
  final Color keyColor;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  const _DialKey({
    required this.display,
    required this.subLabel,
    required this.keyColor,
    required this.onTap,
    this.onLongPress,
  });

  @override
  State<_DialKey> createState() => _DialKeyState();
}

class _DialKeyState extends State<_DialKey>
    with SingleTickerProviderStateMixin {
  late final AnimationController _ctrl;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    // Spec: scale 1.0 → 0.88, 80ms ease-out.
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 80),
      reverseDuration: const Duration(milliseconds: 140),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.88).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeOut),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return AnimatedBuilder(
      animation: _scale,
      builder: (_, child) =>
          Transform.scale(scale: _scale.value, child: child),
      child: Material(
        color: widget.keyColor,
        shape: const CircleBorder(),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          customBorder: const CircleBorder(),
          onTap: widget.onTap,
          onLongPress: widget.onLongPress,
          // Drive the press-scale from the ripple highlight state.
          onHighlightChanged: (pressed) =>
              pressed ? _ctrl.forward() : _ctrl.reverse(),
          child: SizedBox(
            width: 56,
            height: 56,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Text(
                  widget.display,
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.w400,
                    height: widget.subLabel.isEmpty ? 1.0 : 1.1,
                    color: theme.textTheme.bodyLarge?.color,
                  ),
                ),
                if (widget.subLabel.isNotEmpty)
                  Text(
                    widget.subLabel,
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w400,
                      letterSpacing: 1.5,
                      height: 1.0,
                      color: theme.textTheme.bodyMedium?.color
                          ?.withValues(alpha: 0.65),
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

// ── Call button ───────────────────────────────────────────────────────────────

class _CallButton extends StatelessWidget {
  final bool enabled;
  const _CallButton({required this.enabled});

  @override
  Widget build(BuildContext context) {
    final color = enabled
        ? AppColors.callAnswerGreen
        : AppColors.callAnswerGreen.withValues(alpha: 0.35);

    return GestureDetector(
      onTap: enabled
          ? () {
              context.read<DialerBloc>().add(const MakeCall());
              // The dialer lives in a modal bottom sheet (launched from the
              // FAB); dismiss it so the system dialer / call UI is unobstructed.
              Navigator.of(context).maybePop();
            }
          : null,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        width: 72,
        height: 72,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          boxShadow: enabled
              ? [
                  BoxShadow(
                    color: AppColors.callAnswerGreen.withValues(alpha: 0.4),
                    blurRadius: 14,
                    offset: const Offset(0, 4),
                  ),
                ]
              : [],
        ),
        child: const Icon(Icons.phone, color: Colors.white, size: 30),
      ),
    );
  }
}

// ── Contact suggestion rows ───────────────────────────────────────────────────-

class _ContactRow extends StatelessWidget {
  final ContactModel contact;
  final ThemeData theme;

  const _ContactRow({required this.contact, required this.theme});

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
                      PersianUtils.toPersianNumber(phone),
                      style: TextStyle(
                        fontSize: 13,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                    ),
                  ),
                ],
              ),
            ),
            Icon(
              Icons.phone_outlined,
              size: 20,
              color: theme.colorScheme.primary,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    if (contact.avatar != null) {
      return CircleAvatar(
        radius: 22,
        backgroundImage: MemoryImage(contact.avatar!),
      );
    }
    return AvatarWidget(name: contact.name, size: 44);
  }
}

class _UnknownRow extends StatelessWidget {
  final String phone;
  final ThemeData theme;

  const _UnknownRow({required this.phone, required this.theme});

  @override
  Widget build(BuildContext context) {
    return Padding(
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
                    PersianUtils.toPersianNumber(phone),
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
    );
  }
}
