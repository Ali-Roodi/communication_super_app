import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/edition/app_edition.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import '../bloc/edition_bloc.dart';
import '../widgets/activation_code_form.dart';

/// «نسخه بین‌سازمانی» — shows the device code and takes the activation code.
/// Commercial build only; the organization build compiles the row out and
/// asks for its own code before anything else (`OrganizationActivationGate`).
class InterOrgActivationScreen extends StatelessWidget {
  const InterOrgActivationScreen({super.key});

  Future<void> _confirmDeactivate(BuildContext context) async {
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
    if (confirmed == true && context.mounted) {
      context.read<EditionBloc>().add(const DeactivateInterOrganization());
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
                a.edition != AppEdition.interOrganization &&
                b.edition == AppEdition.interOrganization,
            listener: (context, _) {
              HapticFeedback.mediumImpact();
              ScaffoldMessenger.of(context).showSnackBar(
                const SnackBar(content: Text('نسخه بین‌سازمانی فعال شد')),
              );
            },
            buildWhen: (a, b) => a.loaded != b.loaded || a.edition != b.edition,
            builder: (context, state) {
              // Loading is one secure-storage read and one channel call; a
              // spinner for that would only flash.
              if (!state.loaded) return const SizedBox.shrink();
              return ListView(
                padding: const EdgeInsets.all(AppDimensions.paddingLg),
                children: state.edition == AppEdition.interOrganization
                    ? _activeContent(context, state)
                    : const [
                        ActivationCodeForm(
                          intro:
                              'کد دستگاه زیر را به پشتیبانی اعلام کنید و کد '
                              'فعال‌سازی‌ای را که دریافت می‌کنید، این‌جا وارد '
                              'کنید.',
                          unavailableText:
                              'شناسه این دستگاه خوانده نشد؛ فعال‌سازی نسخه '
                              'بین‌سازمانی روی این دستگاه ممکن نیست.',
                        ),
                      ],
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
        DeviceCodeCard(code: state.deviceCode!),
      ],
      const SizedBox(height: AppDimensions.paddingLg),
      OutlinedButton(
        onPressed: () => _confirmDeactivate(context),
        child: const Text('غیرفعال کردن'),
      ),
    ];
  }
}
