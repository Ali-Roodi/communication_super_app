import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import '../bloc/auth_bloc.dart';
import '../bloc/auth_event.dart';
import '../bloc/auth_state.dart';

/// Shows a freshly minted recovery code — **once**.
///
/// The code is stored only as a hash, so this screen is the single moment it
/// can be read. It therefore refuses to be dismissed by the back gesture and
/// requires an explicit «ذخیره کردم» acknowledgement, the same way an app that
/// hands out 2FA backup codes does.
class RecoveryCodeScreen extends StatefulWidget {
  const RecoveryCodeScreen({
    super.key,
    required this.code,
    this.duringSetup = false,
  });

  final String code;

  /// True when this is part of setting a PIN — the copy then explains why the
  /// user is being handed a code they did not ask for.
  final bool duringSetup;

  @override
  State<RecoveryCodeScreen> createState() => _RecoveryCodeScreenState();
}

class _RecoveryCodeScreenState extends State<RecoveryCodeScreen> {
  bool _acknowledged = false;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      // Leaving without reading it means losing it: there is no second look.
      canPop: false,
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppDimensions.paddingLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Spacer(),
                  Icon(
                    Icons.key_outlined,
                    size: 56,
                    color: theme.colorScheme.primary,
                  ),
                  const SizedBox(height: AppDimensions.paddingMd),
                  Text(
                    'کد بازیابی',
                    style: theme.textTheme.headlineSmall,
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppDimensions.paddingSm),
                  Text(
                    widget.duringSetup
                        ? 'اگر رمز عبور را فراموش کنید، تنها راه باز کردن '
                              'برنامه همین کد است. آن را یادداشت کنید و جایی '
                              'امن نگه دارید — این کد فقط همین یک بار نمایش '
                              'داده می‌شود.'
                        : 'کد قبلی از این پس کار نمی‌کند. این کد را یادداشت '
                              'کنید؛ فقط همین یک بار نمایش داده می‌شود.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                    textAlign: TextAlign.center,
                  ),
                  const SizedBox(height: AppDimensions.paddingLg),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      vertical: AppDimensions.paddingMd,
                    ),
                    decoration: BoxDecoration(
                      color: theme.colorScheme.raisedSurface,
                      borderRadius: BorderRadius.circular(
                        AppDimensions.radiusLg,
                      ),
                    ),
                    child: Center(
                      child: SelectableText(
                        widget.code,
                        // Latin, grouped, LTR — reading it back off paper is
                        // the whole job, so it must not be reordered by the
                        // surrounding RTL direction.
                        textDirection: TextDirection.ltr,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          letterSpacing: 2,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: AppDimensions.paddingSm),
                  TextButton.icon(
                    onPressed: () {
                      Clipboard.setData(ClipboardData(text: widget.code));
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('کد بازیابی کپی شد')),
                      );
                    },
                    icon: const Icon(Icons.copy_outlined),
                    label: const Text('کپی'),
                  ),
                  const Spacer(),
                  CheckboxListTile(
                    value: _acknowledged,
                    onChanged: (v) =>
                        setState(() => _acknowledged = v ?? false),
                    controlAffinity: ListTileControlAffinity.leading,
                    title: const Text('این کد را در جای امنی ذخیره کردم'),
                  ),
                  const SizedBox(height: AppDimensions.paddingSm),
                  FilledButton(
                    onPressed: _acknowledged
                        ? () => Navigator.of(context).pop(true)
                        : null,
                    child: const Text('ادامه'),
                  ),
                  const SizedBox(height: AppDimensions.paddingMd),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// «رمز را فراموش کرده‌ام» — asks for the recovery code and, on a match, drops
/// the app to the set-a-new-PIN flow (`AuthBloc` clears the credential).
///
/// It deliberately does not unlock the app directly: a code written on paper
/// must not double as a password.
class RecoveryEntryScreen extends StatefulWidget {
  const RecoveryEntryScreen({super.key});

  @override
  State<RecoveryEntryScreen> createState() => _RecoveryEntryScreenState();
}

class _RecoveryEntryScreenState extends State<RecoveryEntryScreen> {
  final TextEditingController _controller = TextEditingController();
  bool _submitting = false;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final code = _controller.text.trim();
    if (code.isEmpty) return;
    setState(() => _submitting = true);
    context.read<AuthBloc>().add(RecoverWithCode(code));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return BlocListener<AuthBloc, AuthState>(
      listener: (context, state) {
        if (state is AuthValidationFailure) {
          setState(() => _submitting = false);
          HapticFeedback.heavyImpact();
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(SnackBar(content: Text(state.error)));
        }
        if (state is AuthNotSet) {
          // Credential cleared — the wrapper below now shows the setup flow.
          Navigator.of(context).popUntil((route) => route.isFirst);
        }
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: AppBar(title: const Text('بازیابی رمز عبور')),
          body: SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(AppDimensions.paddingLg),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const SizedBox(height: AppDimensions.paddingLg),
                  Text(
                    'کد بازیابی‌ای که هنگام تنظیم رمز عبور یادداشت کردید را '
                    'وارد کنید. با تأیید آن، رمز فعلی پاک می‌شود و رمز تازه‌ای '
                    'تنظیم می‌کنید. پیام‌ها و مخاطبین دست‌نخورده می‌مانند.',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: AppDimensions.paddingLg),
                  TextField(
                    controller: _controller,
                    autofocus: true,
                    textDirection: TextDirection.ltr,
                    textCapitalization: TextCapitalization.characters,
                    // Dashes and case are normalized away before checking, so
                    // the field can stay as forgiving as paper is.
                    decoration: const InputDecoration(
                      labelText: 'کد بازیابی',
                      hintText: 'ABCD-EFGH-JKLM',
                      border: OutlineInputBorder(),
                    ),
                    onSubmitted: (_) => _submit(),
                  ),
                  const SizedBox(height: AppDimensions.paddingLg),
                  FilledButton(
                    onPressed: _submitting ? null : _submit,
                    child: _submitting
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('تأیید'),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// The «رمز را فراموش کرده‌ام» link both lock screens carry.
class ForgotPinButton extends StatelessWidget {
  const ForgotPinButton({super.key});

  @override
  Widget build(BuildContext context) {
    return TextButton(
      onPressed: () => Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const RecoveryEntryScreen()),
      ),
      child: const Text('رمز را فراموش کرده‌ام'),
    );
  }
}

/// Shared presenter so every issuer of a code shows it the same way.
Future<void> showRecoveryCode(
  BuildContext context,
  String code, {
  bool duringSetup = false,
}) {
  return Navigator.of(context).push<bool>(
    MaterialPageRoute<bool>(
      fullscreenDialog: true,
      builder: (_) => RecoveryCodeScreen(code: code, duringSetup: duringSetup),
    ),
  );
}
