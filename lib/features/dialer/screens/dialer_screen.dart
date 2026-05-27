import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';

// ── Main screen ───────────────────────────────────────────────────────────────

class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  /// Sub-labels shown below each dial key (standard phone keypad layout)
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
              // Contact suggestions — visible when number is being typed
              Expanded(
                child: state.dialedNumber.isEmpty
                    ? const SizedBox.shrink()
                    : _buildSuggestions(context, state),
              ),
              // Keypad panel — always anchored at bottom
              _buildKeypadPanel(context, state),
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
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      itemCount: contacts.isEmpty ? 1 : contacts.length,
      itemBuilder: (_, i) => contacts.isNotEmpty
          ? _ContactRow(contact: contacts[i], theme: theme)
          : _UnknownRow(phone: state.dialedNumber, theme: theme),
    );
  }

  // ── Keypad panel ──────────────────────────────────────────────────────────

  Widget _buildKeypadPanel(BuildContext context, DialerState state) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final hasNumber = state.dialedNumber.isNotEmpty;
    // Disable call button while a call is already in progress
    final canCall = hasNumber && !state.isInCall;

    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── Number display ──────────────────────────────────
            SizedBox(
              height: 60,
              child: Center(
                child: hasNumber
                    ? Directionality(
                        textDirection: TextDirection.ltr,
                        child: Text(
                          PersianUtils.toPersianNumber(state.dialedNumber),
                          style: TextStyle(
                            fontSize: 34,
                            fontWeight: FontWeight.w300,
                            color: theme.textTheme.bodyLarge?.color,
                            letterSpacing: 2,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          textAlign: TextAlign.center,
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
            const SizedBox(height: 16),

            // ── Keypad grid (4 rows × 3 cols) ───────────────────
            // Force LTR so digits 1-2-3 always appear left→right,
            // matching the universal phone keypad layout.
            Directionality(
              textDirection: TextDirection.ltr,
              child: Column(
                children: [
                  for (final row in _keyRows) ...[
                    Row(
                      mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                      children: row
                          .map((k) => _DialKey(
                                display: k[0],
                                value: k[1],
                                subLabel: _keySubLabels[k[1]] ?? '',
                                isDark: isDark,
                              ))
                          .toList(),
                    ),
                    const SizedBox(height: 12),
                  ],

                  const SizedBox(height: 4),

                  // ── Call button row ───────────────────────────
                  // Layout: [spacer] [call btn] [backspace]
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      // Spacer — mirrors backspace width for symmetry
                      const SizedBox(width: 72 + 20),
                      // Green call button
                      _CallButton(enabled: canCall),
                      const SizedBox(width: 20),
                      // Backspace: tap = delete last, long-press = clear all
                      SizedBox(
                        width: 72,
                        child: AnimatedOpacity(
                          opacity: hasNumber ? 1.0 : 0.0,
                          duration: const Duration(milliseconds: 200),
                          child: Center(
                            child: GestureDetector(
                              onTap: hasNumber
                                  ? () => context
                                      .read<DialerBloc>()
                                      .add(const DialerNumberDeleted())
                                  : null,
                              onLongPress: hasNumber
                                  ? () => context
                                      .read<DialerBloc>()
                                      .add(const DialerNumberCleared())
                                  : null,
                              child: Container(
                                width: 52,
                                height: 52,
                                decoration: BoxDecoration(
                                  color: isDark
                                      ? Colors.white.withValues(alpha: 0.08)
                                      : Colors.black.withValues(alpha: 0.06),
                                  shape: BoxShape.circle,
                                ),
                                child: Icon(
                                  Icons.backspace_outlined,
                                  size: 22,
                                  color: isDark
                                      ? Colors.white70
                                      : Colors.black54,
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
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

// ── Animated dial key ─────────────────────────────────────────────────────────

class _DialKey extends StatefulWidget {
  final String display;   // Persian character to display
  final String value;     // ASCII value sent to BLoC
  final String subLabel;  // Letters shown below the digit
  final bool isDark;

  const _DialKey({
    required this.display,
    required this.value,
    required this.subLabel,
    required this.isDark,
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
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 60),
      reverseDuration: const Duration(milliseconds: 160),
    );
    _scale = Tween<double>(begin: 1.0, end: 0.86).animate(
      CurvedAnimation(parent: _ctrl, curve: Curves.easeIn),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _onTapDown(TapDownDetails _) => _ctrl.forward();

  void _onTapUp(TapUpDetails _) {
    _ctrl.reverse();
    context.read<DialerBloc>().add(DialerNumberPressed(widget.value));
  }

  void _onTapCancel() => _ctrl.reverse();

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isSpecial = widget.value == '*' || widget.value == '#';

    return GestureDetector(
      onTapDown: _onTapDown,
      onTapUp: _onTapUp,
      onTapCancel: _onTapCancel,
      child: AnimatedBuilder(
        animation: _scale,
        builder: (_, child) =>
            Transform.scale(scale: _scale.value, child: child),
        child: Container(
          width: 72,
          height: 72,
          decoration: BoxDecoration(
            color: widget.isDark ? AppColors.keypadDark : Colors.white,
            shape: BoxShape.circle,
            boxShadow: widget.isDark
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 6,
                      offset: const Offset(0, 2),
                    ),
                  ],
          ),
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Text(
                widget.display,
                style: TextStyle(
                  fontSize: isSpecial ? 22 : 26,
                  fontWeight: FontWeight.w400,
                  color: isSpecial
                      ? theme.textTheme.bodyMedium?.color
                      : theme.textTheme.bodyLarge?.color,
                  height: widget.subLabel.isEmpty ? 1.0 : 1.25,
                ),
              ),
              if (widget.subLabel.isNotEmpty)
                Text(
                  widget.subLabel,
                  style: TextStyle(
                    fontSize: 8,
                    fontWeight: FontWeight.w700,
                    color: theme.textTheme.bodyMedium?.color
                        ?.withValues(alpha: 0.65),
                    letterSpacing: 1.2,
                    height: 1.0,
                  ),
                ),
            ],
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
          ? () => context.read<DialerBloc>().add(const MakeCall())
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

// ── Contact suggestion rows ───────────────────────────────────────────────────

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
        padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
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
      padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 4),
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
