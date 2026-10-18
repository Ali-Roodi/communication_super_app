import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

/// «مسدود کردن تماس» — every rule that refuses a call by what kind of caller
/// it is, as opposed to the list of numbers in «هرزنامه و مسدودشده»:
///
/// - «تماس‌های ناشناس» — no caller id at all ([BoolSetting.blockUnknownCallers]);
/// - «شماره‌های خارج از مخاطبین» ([BoolSetting.blockNonContacts]);
/// - «تماس‌های بین‌المللی» ([BoolSetting.blockInternational]);
/// - «تماس‌های تبلیغاتی» by prefix ([BoolSetting.blockAdvertising],
///   [SettingsState.adPrefixes]).
///
/// All are applied natively in `CallInCallService.onCallAdded` (`CallRules`),
/// so they only work while this app is the default phone app — the page says
/// so when it is not. Reached from Settings and from «هرزنامه و مسدودشده».
class CallBlockRulesPage extends StatefulWidget {
  const CallBlockRulesPage({super.key});

  @override
  State<CallBlockRulesPage> createState() => _CallBlockRulesPageState();
}

class _CallBlockRulesPageState extends State<CallBlockRulesPage> {
  bool? _isDefaultDialer;

  @override
  void initState() {
    super.initState();
    NativeCallService.instance.isDefaultDialer().then((value) {
      if (mounted) setState(() => _isDefaultDialer = value);
    });
  }

  void _setBool(BoolSetting key, bool value) =>
      context.read<SettingsBloc>().add(SetBoolSetting(key, value));

  Future<void> _addPrefix(List<String> current) async {
    final controller = TextEditingController();
    String? error;
    final added = await showDialog<List<String>>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: StatefulBuilder(
          builder: (ctx, setLocal) {
            void submit() {
              final next = CallBlockPrefixes.add(current, controller.text);
              if (next == null) {
                setLocal(
                  () => error =
                      'پیش‌شماره باید دست‌کم ۴ رقم باشد و با ۰ شروع شود، '
                      'مثل ۰۹۴۲',
                );
                return;
              }
              Navigator.of(ctx).pop(next);
            }

            return AlertDialog(
              title: const Text('افزودن پیش‌شماره'),
              content: TextField(
                controller: controller,
                autofocus: true,
                keyboardType: TextInputType.phone,
                textDirection: TextDirection.ltr,
                decoration: InputDecoration(
                  hintText: '۰۹۴۲',
                  helperText:
                      'تماس از شماره‌هایی که با این شروع شوند رد می‌شود',
                  errorText: error,
                  errorMaxLines: 2,
                  helperMaxLines: 2,
                ),
                onSubmitted: (_) => submit(),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('انصراف'),
                ),
                TextButton(onPressed: submit, child: const Text('افزودن')),
              ],
            );
          },
        ),
      ),
    );
    controller.dispose();
    if (added == null || !mounted) return;
    context.read<SettingsBloc>().add(SetAdPrefixes(added));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'مسدود کردن تماس'),
        body: BlocBuilder<SettingsBloc, SettingsState>(
          builder: (context, state) => ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              if (_isDefaultDialer == false)
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(
                    'این قوانین فقط وقتی اجرا می‌شوند که هم‌رسان برنامهٔ تلفن '
                    'پیش‌فرض گوشی باشد (تنظیمات ← برنامه‌های پیش‌فرض).',
                    style: theme.textTheme.bodyMedium?.copyWith(
                      color: theme.colorScheme.error,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                child: Text(
                  'تماس رد شده زنگ نمی‌خورد و در «اخیر» دیده می‌شود. مخاطبان '
                  'ذخیره‌شده و شماره‌های کوتاه خدماتی و اضطراری (مثل ۱۱۰ و ۱۱۵) '
                  'با این قوانین مسدود نمی‌شوند.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
              const SectionLabel('قوانین'),
              GroupedList(
                children: [
                  SwitchListTile(
                    secondary: const Icon(Icons.phone_disabled_outlined),
                    title: const Text('تماس‌های ناشناس'),
                    subtitle: const Text(
                      'تماس‌هایی که شماره‌ای نشان نمی‌دهند (خصوصی یا مخفی)',
                    ),
                    value: state.blockUnknownCallers,
                    onChanged: (v) =>
                        _setBool(BoolSetting.blockUnknownCallers, v),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.person_off_outlined),
                    title: const Text('شماره‌های خارج از مخاطبین'),
                    subtitle: const Text(
                      'فقط مخاطبان ذخیره‌شده، و شماره‌هایی که در ۷ روز گذشته '
                      'خودتان با آن‌ها تماس گرفته‌اید، می‌توانند تماس بگیرند',
                    ),
                    value: state.blockNonContacts,
                    onChanged: (v) => _setBool(BoolSetting.blockNonContacts, v),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.public_off_outlined),
                    title: const Text('تماس‌های بین‌المللی'),
                    subtitle: const Text(
                      'تماس از شماره‌های خارج از ایران، به‌جز مخاطبان',
                    ),
                    value: state.blockInternational,
                    onChanged: (v) =>
                        _setBool(BoolSetting.blockInternational, v),
                  ),
                  SwitchListTile(
                    secondary: const Icon(Icons.campaign_outlined),
                    title: const Text('تماس‌های تبلیغاتی'),
                    subtitle: const Text(
                      'تماس از پیش‌شماره‌های فهرست زیر، به‌جز مخاطبان',
                    ),
                    value: state.blockAdvertising,
                    onChanged: (v) => _setBool(BoolSetting.blockAdvertising, v),
                  ),
                ],
              ),
              const SectionLabel('پیش‌شماره‌های تبلیغاتی'),
              GroupedList(
                children: [
                  for (final prefix in state.adPrefixes)
                    ListTile(
                      leading: const Icon(Icons.dialpad_outlined),
                      title: Text(
                        PersianUtils.toPersianNumber(prefix),
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                      ),
                      trailing: IconButton(
                        icon: const Icon(Icons.delete_outline),
                        tooltip: 'حذف',
                        onPressed: () => context.read<SettingsBloc>().add(
                          SetAdPrefixes([
                            for (final p in state.adPrefixes)
                              if (p != prefix) p,
                          ]),
                        ),
                      ),
                    ),
                  ListTile(
                    leading: const Icon(Icons.add),
                    title: const Text('افزودن پیش‌شماره'),
                    onTap: () => _addPrefix(state.adPrefixes),
                  ),
                ],
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                child: Text(
                  'برای تماس‌های تبلیغاتی شمارهٔ رسمی مشخصی وجود ندارد. '
                  '۰۹۴۲ پیش‌شماره‌ای است که تماس‌های ضبط‌شدهٔ تبلیغاتی از آن '
                  'گزارش شده است؛ هر پیش‌شمارهٔ دیگری را هم می‌توانید اضافه کنید.',
                  style: theme.textTheme.bodySmall,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
