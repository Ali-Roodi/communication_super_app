import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/features/authentication/services/app_lock_platform.dart';
import 'package:communication_super_app/features/authentication/services/biometric_unlock.dart';
import 'package:communication_super_app/features/dialer/widgets/dialer_widgets.dart'
    show DialKey;

/// Row of 4 PIN dots that fill (in the primary colour) as digits are entered.
///
/// The dots fill LEFT to right, whatever the page direction. A PIN is a
/// number, typed on a keypad that is itself forced LTR ([PinKeypad]); in the
/// inherited RTL direction the first digit lit the rightmost dot, so the row
/// filled backwards relative to the digits being typed.
class PinDots extends StatelessWidget {
  final int length;
  final int filled;

  const PinDots({super.key, this.length = 4, required this.filled});

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      textDirection: TextDirection.ltr,
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

  /// What sits left of ۰ — the fingerprint key on the lock screens
  /// ([BiometricUnlockKey]); empty when null.
  final Widget? leading;

  const PinKeypad({
    super.key,
    required this.onKey,
    required this.onDelete,
    this.enabled = true,
    this.leading,
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
                // Keeps 0 centred (the dialer has * here). Empty unless a
                // lock screen puts its fingerprint key there.
                cell(leading ?? const SizedBox(height: 62)),
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

/// «باز کردن با اثر انگشت یا چهره» on a lock screen: the key left of ۰, and
/// the prompt it raises by itself when the screen comes up.
///
/// Renders the empty slot when the setting is off, so the keypad is
/// pixel-for-pixel what it was. The automatic prompt is shown once per
/// appearance of the lock, and only while the app is in front **and** the lock
/// is the top route — a lock that a ringing call's screen sits over must not
/// throw a system prompt across the call. After that the key raises it again;
/// a real trip out of the app (not the prompt itself, see [AppHandoff]) re-arms
/// the automatic one.
class BiometricUnlockKey extends StatefulWidget {
  const BiometricUnlockKey({
    super.key,
    required this.onUnlocked,
    required this.onMessage,
    this.service,
    this.isEnabled,
    this.attempt,
    this.label = 'ورود با اثر انگشت یا چهره',
  });

  /// The biometric matched. The screen opens the app exactly as for a PIN.
  final Future<void> Function() onUnlocked;

  /// Something the user has to be told («اثر انگشت گوشی تغییر کرده…»).
  final void Function(String message) onMessage;

  /// For tests.
  final BiometricUnlock? service;

  /// Another lock's biometric — the secure section's, whose own setting and
  /// key-bound prompt replace the app lock's [BiometricUnlock]. Both or none.
  final Future<bool> Function()? isEnabled;
  final Future<BiometricUnlockOutcome> Function()? attempt;

  /// What a screen reader says for the key.
  final String label;

  @override
  State<BiometricUnlockKey> createState() => _BiometricUnlockKeyState();
}

class _BiometricUnlockKeyState extends State<BiometricUnlockKey>
    with WidgetsBindingObserver {
  late final BiometricUnlock _service = widget.service ?? BiometricUnlock();

  bool _enabled = false;
  bool _busy = false;

  /// The automatic prompt was already shown for this appearance of the lock.
  bool _autoShown = false;

  /// The app went to the background for real since the last prompt.
  bool _wentAway = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    (widget.isEnabled ?? _service.isEnabled)().then((enabled) {
      if (!mounted || !enabled) return;
      setState(() => _enabled = true);
      WidgetsBinding.instance.addPostFrameCallback((_) => _maybeAuto());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    // The PIN was typed while the prompt was up and the lock is gone: a
    // system prompt left floating over the open app would be absurd.
    if (_busy) AppLockPlatform.cancelAuthentication();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.paused:
      case AppLifecycleState.hidden:
        // The prompt the app raised itself is not "leaving".
        if (!AppHandoff.active) _wentAway = true;
      case AppLifecycleState.resumed:
        if (_wentAway) {
          _wentAway = false;
          _autoShown = false;
        }
        _maybeAuto();
      case AppLifecycleState.inactive:
      case AppLifecycleState.detached:
        break;
    }
  }

  void _maybeAuto() {
    if (!mounted || !_enabled || _autoShown || _busy) return;
    if (WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) {
      return;
    }
    if (ModalRoute.of(context)?.isCurrent == false) return;
    // A call that cold-started the app may still be on its way to the screen
    // (the route check above can run before its screen is pushed): never
    // throw a system prompt in front of a ringing or live call.
    if (_callUp()) return;
    _autoShown = true;
    _prompt();
  }

  bool _callUp() {
    try {
      final dialer = context.read<DialerBloc>().state;
      return dialer.isInCall || dialer.callStatus == CallStatus.incoming;
    } catch (_) {
      // No DialerBloc above (a test, or a screen built outside the app).
      return false;
    }
  }

  Future<void> _prompt() async {
    if (_busy) return;
    setState(() => _busy = true);
    final outcome = await (widget.attempt ?? _service.unlock)();
    if (!mounted) return;
    setState(() => _busy = false);
    switch (outcome) {
      case BiometricUnlockOutcome.unlocked:
        await widget.onUnlocked();
        return;
      case BiometricUnlockOutcome.enrollmentChanged:
      case BiometricUnlockOutcome.notEnabled:
        setState(() => _enabled = false);
      case BiometricUnlockOutcome.cancelled:
      case BiometricUnlockOutcome.unavailable:
      case BiometricUnlockOutcome.lockedOut:
      case BiometricUnlockOutcome.failed:
        break;
    }
    final message = BiometricUnlock.messageFor(outcome);
    if (message != null) widget.onMessage(message);
  }

  @override
  Widget build(BuildContext context) {
    if (!_enabled) return const SizedBox(height: 62);
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: widget.label,
      child: Material(
        color: scheme.keySurface,
        borderRadius: BorderRadius.circular(34),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: _busy ? null : _prompt,
          child: SizedBox(
            height: 62,
            child: Icon(Icons.fingerprint, size: 30, color: scheme.primary),
          ),
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
