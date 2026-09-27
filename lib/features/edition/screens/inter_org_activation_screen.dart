import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/activation_code.dart';
import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import '../bloc/edition_bloc.dart';

/// «نسخه بین‌سازمانی» — shows the device code and takes the activation code.
///
/// The flow is offline by design: the user reads the device code to the
/// mentor (in person or by phone), the mentor's Windows app answers with the
/// activation code, the user types it here. See [ActivationCode].
class InterOrgActivationScreen extends StatefulWidget {
  const InterOrgActivationScreen({super.key});

  @override
  State<InterOrgActivationScreen> createState() =>
      _InterOrgActivationScreenState();
}

class _InterOrgActivationScreenState extends State<InterOrgActivationScreen> {
  final TextEditingController _controller = TextEditingController();

  /// The failure is shown until the user edits the code — an error that
  /// outlives the text it was about reads as a verdict on the new text.
  bool _showFailure = false;

  /// What the listener last saw, so it reacts to a *change* — a new failure,
  /// or the moment of activation — and not to every rebuild.
  late int _seenFailures;
  late AppEdition _seenEdition;

  @override
  void initState() {
    super.initState();
    final state = context.read<EditionBloc>().state;
    _seenFailures = state.failedAttempts;
    _seenEdition = state.edition;
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
    context.read<EditionBloc>().add(
      ActivateInterOrganization(_controller.text),
    );
  }

  Future<void> _confirmDeactivate() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('غیرفعال کردن نسخه بین‌سازمانی؟'),
          content: const Text(
            'برنامه به نسخه تجاری برمی‌گردد. برای فعال‌سازی دوباره، همان کد '
            'فعال‌سازی این دستگاه کافی است.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(context).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.of(context).pop(true),
              child: const Text('غیرفعال کردن'),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) {
      _controller.clear();
      context.read<EditionBloc>().add(const DeactivateInterOrganization());
    }
  }

  void _onStateChanged(BuildContext context, EditionState state) {
    final failedNow = state.failedAttempts > _seenFailures;
    final activatedNow =
        _seenEdition != AppEdition.interOrganization &&
        state.edition == AppEdition.interOrganization;
    _seenFailures = state.failedAttempts;
    _seenEdition = state.edition;
    if (failedNow) {
      HapticFeedback.heavyImpact();
      setState(() => _showFailure = true);
    }
    if (activatedNow) {
      HapticFeedback.mediumImpact();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('نسخه بین‌سازمانی فعال شد')));
    }
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(title: const Text('نسخه بین‌سازمانی')),
        body: SafeArea(
          child: BlocConsumer<EditionBloc, EditionState>(
            listenWhen: (a, b) =>
                a.failedAttempts != b.failedAttempts || a.edition != b.edition,
            listener: _onStateChanged,
            builder: (context, state) {
              // Loading is one secure-storage read and one channel call; a
              // spinner for that would only flash.
              if (!state.loaded) return const SizedBox.shrink();
              return ListView(
                padding: const EdgeInsets.all(AppDimensions.paddingLg),
                children: state.edition == AppEdition.interOrganization
                    ? _activeContent(context, state)
                    : _activationContent(context, state),
              );
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _activeContent(BuildContext context, EditionState state) {
    final theme = Theme.of(context);
    return [
      const SizedBox(height: AppDimensions.paddingLg),
      Icon(Icons.verified_outlined, size: 56, color: theme.colorScheme.primary),
      const SizedBox(height: AppDimensions.paddingMd),
      Text(
        'نسخه بین‌سازمانی فعال است',
        style: theme.textTheme.headlineSmall,
        textAlign: TextAlign.center,
      ),
      const SizedBox(height: AppDimensions.paddingSm),
      Text(
        'قابلیت‌های نسخه بین‌سازمانی روی این دستگاه باز شده‌اند.',
        style: theme.textTheme.bodyMedium?.copyWith(
          color: theme.colorScheme.onSurfaceVariant,
        ),
        textAlign: TextAlign.center,
      ),
      if (state.deviceCode != null) ...[
        const SizedBox(height: AppDimensions.paddingLg),
        _DeviceCodeCard(code: state.deviceCode!),
      ],
      const SizedBox(height: AppDimensions.paddingLg),
      OutlinedButton(
        onPressed: _confirmDeactivate,
        child: const Text('غیرفعال کردن'),
      ),
    ];
  }

  List<Widget> _activationContent(BuildContext context, EditionState state) {
    final theme = Theme.of(context);
    final muted = theme.textTheme.bodyMedium?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    if (state.deviceCodeUnavailable || state.deviceCode == null) {
      return [
        const SizedBox(height: AppDimensions.paddingLg),
        Icon(Icons.error_outline, size: 56, color: theme.colorScheme.error),
        const SizedBox(height: AppDimensions.paddingMd),
        Text(
          'شناسه این دستگاه خوانده نشد؛ فعال‌سازی نسخه بین‌سازمانی روی این '
          'دستگاه ممکن نیست.',
          style: muted,
          textAlign: TextAlign.center,
        ),
      ];
    }

    final failure = _showFailure ? state.lastFailure : null;
    return [
      Text(
        'کد دستگاه زیر را به پشتیبانی اعلام کنید و کد فعال‌سازی‌ای را که '
        'دریافت می‌کنید، این‌جا وارد کنید.',
        style: muted,
      ),
      const SizedBox(height: AppDimensions.paddingLg),
      _DeviceCodeCard(code: state.deviceCode!),
      const SizedBox(height: AppDimensions.paddingLg),
      TextField(
        controller: _controller,
        // The code is Latin hex read out loud: a Latin keyboard with no
        // autocorrect, left-to-right, and forgiving of what a person types
        // around it — spaces, dashes, Persian digits (see
        // ActivationCode.normalize).
        textDirection: TextDirection.ltr,
        keyboardType: TextInputType.visiblePassword,
        autocorrect: false,
        enableSuggestions: false,
        inputFormatters: [
          FilteringTextInputFormatter.allow(RegExp(r'[0-9a-fA-F۰-۹٠-٩ \-]')),
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
    ];
  }
}

/// The device code, the way it has to be read aloud: Latin, left-to-right,
/// monospaced, copyable.
class _DeviceCodeCard extends StatelessWidget {
  const _DeviceCodeCard({required this.code});

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
