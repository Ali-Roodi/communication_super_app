import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import '../bloc/edition_bloc.dart';

/// The device code and the field that takes the activation code — the one
/// form both «نسخه بین‌سازمانی» and the organization APK's first screen show.
///
/// The flow is offline by design: the user reads the device code to the
/// mentor (in person or by phone), the Windows app answers with the
/// activation code, the user types it here. See [ActivationCode]. What
/// happens on success is the caller's: [EditionState.activated] turns true.
class ActivationCodeForm extends StatefulWidget {
  const ActivationCodeForm({
    super.key,
    required this.intro,
    required this.unavailableText,
  });

  /// What to do with the device code, above it.
  final String intro;

  /// Shown instead of the form when the device has no identity.
  final String unavailableText;

  @override
  State<ActivationCodeForm> createState() => _ActivationCodeFormState();
}

class _ActivationCodeFormState extends State<ActivationCodeForm> {
  final TextEditingController _controller = TextEditingController();

  /// The failure is shown until the user edits the code — an error that
  /// outlives the text it was about reads as a verdict on the new text.
  bool _showFailure = false;

  /// What the listener last saw, so it reacts to a *new* failure and not to
  /// every rebuild.
  late int _seenFailures;

  @override
  void initState() {
    super.initState();
    _seenFailures = context.read<EditionBloc>().state.failedAttempts;
    _controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    _controller
      ..removeListener(_onTextChanged)
      ..dispose();
    super.dispose();
  }

  void _onTextChanged() {
    // Rebuilds the button's enabled state and clears a stale error.
    setState(() => _showFailure = false);
  }

  bool get _codeComplete => ActivationCode.normalize(_controller.text) != null;

  void _submit() {
    if (!_codeComplete) return;
    FocusScope.of(context).unfocus();
    context.read<EditionBloc>().add(ActivateEdition(_controller.text));
  }

  void _onStateChanged(BuildContext context, EditionState state) {
    final failedNow = state.failedAttempts > _seenFailures;
    _seenFailures = state.failedAttempts;
    if (failedNow) {
      HapticFeedback.heavyImpact();
      setState(() => _showFailure = true);
    }
  }

  @override
  Widget build(BuildContext context) {
    return BlocConsumer<EditionBloc, EditionState>(
      listenWhen: (a, b) => a.failedAttempts != b.failedAttempts,
      listener: _onStateChanged,
      builder: (context, state) {
        final theme = Theme.of(context);
        final muted = theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        );
        if (state.deviceCodeUnavailable || state.deviceCode == null) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              const SizedBox(height: AppDimensions.paddingLg),
              Icon(
                Icons.error_outline,
                size: 56,
                color: theme.colorScheme.error,
              ),
              const SizedBox(height: AppDimensions.paddingMd),
              Text(
                widget.unavailableText,
                style: muted,
                textAlign: TextAlign.center,
              ),
            ],
          );
        }

        final failure = _showFailure ? state.lastFailure : null;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(widget.intro, style: muted),
            const SizedBox(height: AppDimensions.paddingLg),
            DeviceCodeCard(code: state.deviceCode!),
            const SizedBox(height: AppDimensions.paddingLg),
            TextField(
              controller: _controller,
              // The code is Latin hex read out loud: a Latin keyboard with no
              // autocorrect, left-to-right, and forgiving of what a person
              // types around it — spaces, dashes, Persian digits (see
              // ActivationCode.normalize).
              textDirection: TextDirection.ltr,
              keyboardType: TextInputType.visiblePassword,
              autocorrect: false,
              enableSuggestions: false,
              inputFormatters: [
                FilteringTextInputFormatter.allow(
                  RegExp(r'[0-9a-fA-F۰-۹٠-٩ \-]'),
                ),
                LengthLimitingTextInputFormatter(20),
              ],
              style: const TextStyle(fontFamily: 'monospace', letterSpacing: 2),
              decoration: InputDecoration(
                labelText: 'کد فعال‌سازی',
                helperText: 'کد ۱۰ کاراکتری',
                errorText: switch (failure) {
                  ActivationFailure.wrongCode =>
                    'کد فعال‌سازی درست نیست. کد را دوباره بررسی کنید.',
                  ActivationFailure.saveFailed =>
                    'کد درست است اما ذخیره نشد. دوباره تلاش کنید.',
                  null => null,
                },
                border: const OutlineInputBorder(),
              ),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: AppDimensions.paddingLg),
            FilledButton(
              onPressed: _codeComplete && !state.checking ? _submit : null,
              child: state.checking
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('فعال‌سازی'),
            ),
          ],
        );
      },
    );
  }
}

/// The device code, the way it has to be read aloud: Latin, left-to-right,
/// monospaced, copyable.
class DeviceCodeCard extends StatelessWidget {
  const DeviceCodeCard({super.key, required this.code});

  final String code;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          'کد دستگاه',
          style: theme.textTheme.labelLarge?.copyWith(
            color: theme.colorScheme.onSurfaceVariant,
          ),
        ),
        const SizedBox(height: AppDimensions.paddingSm),
        Container(
          padding: const EdgeInsets.symmetric(
            vertical: AppDimensions.paddingMd,
          ),
          decoration: BoxDecoration(
            color: theme.colorScheme.raisedSurface,
            borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
          ),
          child: Center(
            child: SelectableText(
              code,
              // Never Persian digits and never reordered: the mentor types
              // exactly these characters into the Windows app.
              textDirection: TextDirection.ltr,
              style: theme.textTheme.headlineSmall?.copyWith(
                fontFamily: 'monospace',
                letterSpacing: 4,
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: TextButton.icon(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: code));
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(const SnackBar(content: Text('کد دستگاه کپی شد')));
            },
            icon: const Icon(Icons.copy_outlined),
            label: const Text('کپی'),
          ),
        ),
      ],
    );
  }
}
