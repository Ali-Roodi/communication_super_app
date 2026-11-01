import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_picker_sheet.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

/// «فهرست سیاه و سفید» (matrix row 10): for each of SMS in, SMS out, calls in
/// and calls out, whether it is open to everybody but the black list, only to
/// the white list, or to nobody — and the two lists of numbers and patterns.
///
/// The decision is native (`NumberLists`), so it holds with the app closed;
/// receiving is only ours to refuse while this app is the default SMS and
/// phone app, and the page says so when it is not. Reached from Settings and
/// from «هرزنامه و مسدودشده».
class NumberListsPage extends StatefulWidget {
  const NumberListsPage({super.key});

  @override
  State<NumberListsPage> createState() => _NumberListsPageState();
}

class _NumberListsPageState extends State<NumberListsPage> {
  bool _defaultApps = true;

  @override
  void initState() {
    super.initState();
    Future.wait([
      NativeSmsService().isDefaultSmsApp(),
      NativeCallService.instance.isDefaultDialer(),
    ]).then((roles) {
      if (mounted) setState(() => _defaultApps = roles.every((r) => r));
    }, onError: (_) {});
  }

  void _set(NumberLists lists) =>
      context.read<SettingsBloc>().add(SetNumberLists(lists));

  Future<void> _pickMode(NumberLists lists, ListChannel channel) async {
    final current = lists.modeOf(channel);
    final picked = await showDialog<ListMode>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SimpleDialog(
          title: Text(channel.label),
          children: [
            for (final mode in ListMode.values)
              ListTile(
                title: Text(mode.label),
                trailing: mode == current ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(ctx).pop(mode),
              ),
          ],
        ),
      ),
    );
    if (picked == null || picked == current || !mounted) return;
    _set(lists.withMode(channel, picked));
  }

  Future<void> _addEntry(NumberLists lists, {required bool white}) async {
    final list = white ? lists.white : lists.black;
    final next = await showDialog<List<String>>(
      context: context,
      builder: (_) => _AddEntryDialog(
        title: white ? 'افزودن به فهرست سفید' : 'افزودن به فهرست سیاه',
        list: list,
      ),
    );
    if (next == null || !mounted) return;
    _set(white ? lists.copyWith(white: next) : lists.copyWith(black: next));
  }

  void _removeEntry(NumberLists lists, String entry, {required bool white}) {
    final list = [
      for (final e in white ? lists.white : lists.black)
        if (e != entry) e,
    ];
    _set(white ? lists.copyWith(white: list) : lists.copyWith(black: list));
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'فهرست سیاه و سفید'),
        body: BlocBuilder<SettingsBloc, SettingsState>(
          buildWhen: (a, b) => a.numberLists != b.numberLists,
          builder: (context, state) {
            final lists = state.numberLists;
            return ListView(
              padding: const EdgeInsets.only(bottom: 32),
              children: [
                if (!_defaultApps)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                    child: Text(
                      'پیامک‌ها و تماس‌های دریافتی فقط وقتی با این فهرست‌ها رد '
                      'می‌شوند که هم‌رسان برنامهٔ پیامک و تلفن پیش‌فرض گوشی '
                      'باشد (تنظیمات ← برنامه‌های پیش‌فرض).',
                      style: theme.textTheme.bodyMedium?.copyWith(
                        color: theme.colorScheme.error,
                      ),
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
                  child: Text(
                    'برای هر مورد مشخص کنید چه کسانی مجازند. پیامک ردشده جایی '
                    'ذخیره نمی‌شود و تماس ردشده زنگ نمی‌خورد. شماره‌های کوتاه '
                    'خدماتی و اضطراری (مثل ۱۱۰ و ۱۱۵) همیشه مجازند.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
                const SectionLabel('چه کسانی مجازند'),
                GroupedList(
                  children: [
                    for (final channel in ListChannel.values)
                      SettingsRow(
                        icon: _iconOf(channel),
                        title: channel.label,
                        summary: lists.modeOf(channel).label,
                        onTap: () => _pickMode(lists, channel),
                      ),
                  ],
                ),
                const SectionLabel('فهرست سیاه'),
                _EntryList(
                  entries: lists.black,
                  onAdd: () => _addEntry(lists, white: false),
                  onRemove: (e) => _removeEntry(lists, e, white: false),
                ),
                const SectionLabel('فهرست سفید'),
                _EntryList(
                  entries: lists.white,
                  onAdd: () => _addEntry(lists, white: true),
                  onRemove: (e) => _removeEntry(lists, e, white: true),
                  leading: SwitchListTile(
                    secondary: const Icon(Icons.contacts_outlined),
                    title: const Text('مخاطبین ذخیره‌شده هم مجازند'),
                    subtitle: const Text(
                      'در حالت «فقط فهرست سفید»، همهٔ مخاطبان گوشی هم مجاز باشند',
                    ),
                    value: lists.contactsAllowed,
                    onChanged: (v) => _set(lists.copyWith(contactsAllowed: v)),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 12, 24, 0),
                  child: Text(
                    'هر مورد یک شماره یا یک الگوست: «*» یعنی هر تعداد رقم و «؟» یعنی '
                    'یک رقم. مثلاً \u2066۰۹۱۲*\u2069 همهٔ شماره‌هایی که با ۰۹۱۲ شروع '
                    'می‌شوند و \u2066*۱۲۳۴\u2069 شماره‌هایی که به ۱۲۳۴ ختم می‌شوند. '
                    'شماره‌هایی که از گفتگو یا «اخیر» مسدود کرده‌اید در '
                    '«هرزنامه و مسدودشده» هستند و همیشه رد می‌شوند.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            );
          },
        ),
      ),
    );
  }

  static IconData _iconOf(ListChannel channel) => switch (channel) {
    ListChannel.smsIn => Icons.sms_outlined,
    ListChannel.smsOut => Icons.send_outlined,
    ListChannel.callIn => Icons.call_received,
    ListChannel.callOut => Icons.call_made,
  };
}

class _EntryList extends StatelessWidget {
  final List<String> entries;
  final VoidCallback onAdd;
  final ValueChanged<String> onRemove;
  final Widget? leading;

  const _EntryList({
    required this.entries,
    required this.onAdd,
    required this.onRemove,
    this.leading,
  });

  @override
  Widget build(BuildContext context) {
    return GroupedList(
      children: [
        ?leading,
        for (final entry in entries)
          ListTile(
            leading: Icon(
              entry.contains('*') || entry.contains('?')
                  ? Icons.pattern
                  : Icons.dialpad_outlined,
            ),
            title: Text(
              PersianUtils.toPersianNumber(entry).replaceAll('?', '؟'),
              textDirection: TextDirection.ltr,
              textAlign: TextAlign.right,
            ),
            trailing: IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: 'حذف',
              onPressed: () => onRemove(entry),
            ),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('افزودن شماره یا الگو'),
          onTap: onAdd,
        ),
      ],
    );
  }
}

/// Answers the list with the typed entry added, or null when dismissed.
class _AddEntryDialog extends StatefulWidget {
  final String title;
  final List<String> list;
  const _AddEntryDialog({required this.title, required this.list});

  @override
  State<_AddEntryDialog> createState() => _AddEntryDialogState();
}

class _AddEntryDialogState extends State<_AddEntryDialog> {
  final _controller = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _submit() {
    final next = NumberLists.add(widget.list, _controller.text);
    if (next == null) {
      setState(
        () => _error =
            'یک شماره کامل یا الگویی با دست‌کم ۳ رقم که با ۰ یا * شروع شود، '
            'مثل \u2066۰۹۱۲*\u2069',
      );
      return;
    }
    Navigator.of(context).pop(next);
  }

  Future<void> _fromContacts() async {
    final picked = await showContactPickerSheet(context);
    if (picked == null || !mounted) return;
    setState(() {
      _controller.text = picked.number;
      _error = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(widget.title),
        content: TextField(
          controller: _controller,
          autofocus: true,
          keyboardType: TextInputType.phone,
          textDirection: TextDirection.ltr,
          decoration: InputDecoration(
            hintText: '\u2066۰۹۱۲۱۲۳۴۵۶۷\u2069  یا  \u2066۰۹۱۲*\u2069',
            errorText: _error,
            errorMaxLines: 3,
            suffixIcon: IconButton(
              icon: const Icon(Icons.contacts_outlined),
              tooltip: 'از مخاطبین',
              onPressed: _fromContacts,
            ),
          ),
          onSubmitted: (_) => _submit(),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('انصراف'),
          ),
          TextButton(onPressed: _submit, child: const Text('افزودن')),
        ],
      ),
    );
  }
}
