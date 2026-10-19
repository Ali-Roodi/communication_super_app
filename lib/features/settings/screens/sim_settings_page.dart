import 'package:flutter/material.dart';

import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

/// «سیم‌کارت‌ها» — the card calls and SMS use when nothing more specific
/// applies (a pick for one call, a contact's «سیم‌کارت تماس», a
/// conversation's «ارسال با»).
///
/// It starts out as «پیش‌فرض گوشی»: the app does what Android's own SIM
/// settings say, and goes on following them when they change. The app cannot
/// change the phone's setting (no app may), so a card chosen here is the app's
/// own default — stored in [SimService.setAppDefault] and mirrored natively
/// for the dials and replies made with no Flutter engine.
class SimSettingsPage extends StatelessWidget {
  const SimSettingsPage({super.key});

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'سیم‌کارت‌ها'),
        body: SimAware(
          builder: (context, _, _) => ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              const SectionLabel('سیم‌کارت پیش‌فرض'),
              GroupedList(
                children: [
                  SettingsRow(
                    icon: Icons.call_outlined,
                    title: 'تماس‌ها',
                    summary: summaryFor(SimUse.voice),
                    onTap: () => _pick(context, SimUse.voice),
                  ),
                  SettingsRow(
                    icon: Icons.sms_outlined,
                    title: 'پیامک‌ها',
                    summary: summaryFor(SimUse.sms),
                    onTap: () => _pick(context, SimUse.sms),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Text(
                  'سیم‌کارتی که برای یک مخاطب («سیم‌کارت تماس» در صفحهٔ '
                  'مخاطب) یا یک گفتگو («ارسال با») انتخاب کنید، بر این '
                  'تنظیم مقدم است. با نگه داشتن دکمهٔ تماس هم می‌شود برای '
                  'همان یک تماس سیم‌کارت دیگری انتخاب کرد.',
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// What a row says: the chosen card, «هر بار بپرس», or «پیش‌فرض گوشی»
  /// with the card the phone's setting names right now.
  @visibleForTesting
  static String summaryFor(SimUse use) {
    final app = SimService.appDefault(use);
    if (app == SimService.appAsk) return 'هر بار بپرس';
    final own = SimService.byId(app);
    if (own != null) return _label(own);
    final phone = SimService.phoneDefault(use);
    return phone == null
        ? 'پیش‌فرض گوشی · هر بار بپرس'
        : 'پیش‌فرض گوشی · ${_label(phone)}';
  }

  static String _label(SimCard sim) => '${sim.slotLabel} · ${sim.name}';

  Future<void> _pick(BuildContext context, SimUse use) async {
    final app = SimService.appDefault(use);
    final phone = SimService.phoneDefault(use);
    final asking = app == SimService.appAsk;
    final own = SimService.byId(app);
    final choice = await showSimChoice(
      context,
      title: use == SimUse.voice
          ? 'سیم‌کارت پیش‌فرض تماس'
          : 'سیم‌کارت پیش‌فرض پیامک',
      defaultLabel: 'پیش‌فرض گوشی',
      defaultSubtitle: phone == null
          ? 'طبق تنظیم گوشی — الان «هر بار بپرس»'
          : 'طبق تنظیم گوشی — الان ${_label(phone)}',
      selected: own,
      defaultSelected: !asking && own == null,
      // SMS has no «ask»: a conversation names its card on its details page.
      extra: use == SimUse.voice
          ? (sheetContext) => [
              ListTile(
                leading: const Icon(Icons.help_outline),
                title: const Text('هر بار بپرس'),
                trailing: asking
                    ? Icon(
                        Icons.check,
                        color: Theme.of(sheetContext).colorScheme.primary,
                      )
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(_askChoice),
              ),
            ]
          : null,
    );
    if (choice == null) return;
    final value = choice.tag == _askChoice.tag
        ? SimService.appAsk
        : choice.sim?.subscriptionId ?? SimService.appFollowPhone;
    await SimService.instance.setAppDefault(use, value);
  }
}

/// «هر بار بپرس», as the sheet answers it.
const SimChoice _askChoice = SimChoice.other('ask');
