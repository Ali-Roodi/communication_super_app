import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/screens/secure_unlock_screen.dart';

import '../bloc/key_bank_bloc.dart';
import '../services/key_file_service.dart';
import '../services/trust_anchors.dart';

/// «بانک کلید» — Settings → امنیت. Only inside an open secure section.
class KeyBankScreen extends StatelessWidget {
  const KeyBankScreen({super.key, this.keyFiles = const KeyFileService()});

  final KeyFileService keyFiles;

  /// A key id / group id as people read it aloud: `6137-C0D2-134E-F047`.
  static String formatId(String hex) {
    final upper = hex.toUpperCase();
    return [
      for (var i = 0; i < upper.length; i += 4)
        upper.substring(i, (i + 4).clamp(0, upper.length)),
    ].join('-');
  }

  static String noticeText(KeyBankNotice notice) => switch (notice) {
    KeyBankNotice.imported => 'فایل کلید وارد شد',
    KeyBankNotice.updated => 'دفترچه کلید به‌روز شد',
    KeyBankNotice.ownKeyAdded => 'کلید شما به دفترچه اضافه شد',
    KeyBankNotice.alreadyImported => 'این فایل قبلاً وارد شده است',
    KeyBankNotice.older => 'این فایل قدیمی‌تر از دفترچه فعلی است و وارد نشد',
    KeyBankNotice.wrongPassword => 'رمز فایل کلید اشتباه است',
    KeyBankNotice.notAKeyFile => 'این فایل، فایل کلید هم‌رسان نیست',
    KeyBankNotice.untrusted =>
      'این فایل را مرجعی امضا کرده که این برنامه به آن اعتماد ندارد',
    KeyBankNotice.badSignature => 'امضای فایل معتبر نیست؛ فایل دستکاری شده است',
    KeyBankNotice.badBundle => 'محتوای فایل کلید معتبر نیست',
    KeyBankNotice.groupAdded => 'گروه اضافه شد',
    KeyBankNotice.groupExists => 'این گروه قبلاً اضافه شده است',
    KeyBankNotice.numberAdded => 'شماره اضافه شد',
    KeyBankNotice.numberExists => 'این شماره قبلاً اضافه شده است',
    KeyBankNotice.notANumber => 'شماره معتبر نیست',
    KeyBankNotice.failed => 'انجام نشد؛ دوباره تلاش کنید',
  };

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'بانک کلید'),
        body: BlocConsumer<KeyBankBloc, KeyBankState>(
          listenWhen: (a, b) => a.noticeSeq != b.noticeSeq && b.notice != null,
          listener: (context, state) {
            ScaffoldMessenger.of(context)
              ..hideCurrentSnackBar()
              ..showSnackBar(
                SnackBar(content: Text(noticeText(state.notice!))),
              );
          },
          builder: (context, state) => switch (state.status) {
            KeyBankStatus.locked => const _Locked(),
            KeyBankStatus.loading => const SizedBox.shrink(),
            KeyBankStatus.ready => _Bank(state: state, keyFiles: keyFiles),
          },
        ),
      ),
    );
  }
}

class _Locked extends StatelessWidget {
  const _Locked();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.lock_outline,
              size: 48,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
            const SizedBox(height: 16),
            const Text(
              'بانک کلید داخل بخش امن نگهداری می‌شود. برای دیدن یا تغییر آن، '
              'بخش امن را باز کنید.',
              textAlign: TextAlign.center,
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: () => Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (_) => const SecureUnlockScreen()),
              ),
              child: const Text('باز کردن بخش امن'),
            ),
          ],
        ),
      ),
    );
  }
}

class _Bank extends StatelessWidget {
  const _Bank({required this.state, required this.keyFiles});

  final KeyBankState state;
  final KeyFileService keyFiles;

  @override
  Widget build(BuildContext context) {
    final s = state.snapshot;
    final scheme = Theme.of(context).colorScheme;
    return Stack(
      children: [
        ListView(
          padding: const EdgeInsets.only(top: 8, bottom: 32),
          children: [
            if (TrustAnchors.includesDevelopment)
              Container(
                margin: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: scheme.errorContainer,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Text(
                  'نسخه آزمایشی: این برنامه به مرجع آزمایشی (توسعه) اعتماد '
                  'دارد. برای استفاده واقعی مناسب نیست.',
                  style: TextStyle(color: scheme.onErrorContainer),
                ),
              ),
            const _Heading('دفترچه‌های سازمانی'),
            for (final d in s.directories) _DirectoryRow(d),
            _ActionRow(
              icon: Icons.file_open_outlined,
              title: 'وارد کردن فایل کلید',
              summary: 'فایلی که مرجع سازمان با ابزار بانک کلید ساخته',
              onTap: state.busy ? null : () => _importFile(context),
            ),
            const Divider(height: 24),
            const _Heading('گروه‌های عبارت عبور'),
            for (final g in s.groups) _GroupRow(g),
            _ActionRow(
              icon: Icons.group_add_outlined,
              title: 'افزودن گروه',
              summary:
                  'کلید اعضا از نام گروه و یک عبارت عبور مشترک ساخته می‌شود',
              onTap: state.busy ? null : () => _addGroup(context),
            ),
            const Divider(height: 24),
            const _Heading('شماره‌های من'),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 8),
              child: Text(
                'در گروه‌های عبارت عبور، کلید هر عضو از شماره او ساخته می‌شود. '
                'شماره سیم‌کارت‌های همین گوشی را اینجا وارد کنید.',
                style: TextStyle(color: scheme.onSurfaceVariant, fontSize: 13),
              ),
            ),
            for (final n in s.ownNumbers) _NumberRow(n),
            _ActionRow(
              icon: Icons.add_call,
              title: 'افزودن شماره',
              onTap: () => _addNumber(context),
            ),
          ],
        ),
        if (state.busy)
          const Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: LinearProgressIndicator(),
          ),
      ],
    );
  }

  Future<void> _importFile(BuildContext context) async {
    final bloc = context.read<KeyBankBloc>();
    final messenger = ScaffoldMessenger.of(context);
    final Uint8List? file;
    try {
      file = await keyFiles.pick();
    } on KeyFilePickException catch (e) {
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            e.failure == KeyFilePickFailure.tooLarge
                ? 'این فایل، فایل کلید هم‌رسان نیست'
                : 'فایل خوانده نشد',
          ),
        ),
      );
      return;
    }
    if (file == null || !context.mounted) return;
    final password = await _askText(
      context,
      title: 'رمز فایل کلید',
      hint: 'XXXX-XXXX-XXXX-XXXX-XXXX',
      latin: true,
    );
    if (password == null || password.isEmpty) return;
    bloc.add(KeyBankImportFile(file, password));
  }

  Future<void> _addGroup(BuildContext context) async {
    final bloc = context.read<KeyBankBloc>();
    final result = await showDialog<(String, String)>(
      context: context,
      builder: (_) => const _GroupDialog(),
    );
    if (result != null) bloc.add(KeyBankAddGroup(result.$1, result.$2));
  }

  Future<void> _addNumber(BuildContext context) async {
    final bloc = context.read<KeyBankBloc>();
    final number = await _askText(
      context,
      title: 'شماره این گوشی',
      hint: '09121234567',
      phone: true,
    );
    if (number != null && number.trim().isNotEmpty) {
      bloc.add(KeyBankAddOwnNumber(number));
    }
  }
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String hint,
  bool latin = false,
  bool phone = false,
}) {
  final controller = TextEditingController();
  return showDialog<String>(
    context: context,
    builder: (dialogCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          textDirection: TextDirection.ltr,
          keyboardType: phone
              ? TextInputType.phone
              : TextInputType.visiblePassword,
          autocorrect: false,
          enableSuggestions: false,
          textCapitalization: latin
              ? TextCapitalization.characters
              : TextCapitalization.none,
          decoration: InputDecoration(hintText: hint),
          onSubmitted: (v) => Navigator.of(dialogCtx).pop(v),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(controller.text),
            child: const Text('تأیید'),
          ),
        ],
      ),
    ),
  ).whenComplete(controller.dispose);
}

class _GroupDialog extends StatefulWidget {
  const _GroupDialog();

  @override
  State<_GroupDialog> createState() => _GroupDialogState();
}

class _GroupDialogState extends State<_GroupDialog> {
  static const _minLength = 12;

  final _name = TextEditingController();
  final _passphrase = TextEditingController();
  final _repeat = TextEditingController();
  String? _error;

  @override
  void dispose() {
    _name.dispose();
    _passphrase.dispose();
    _repeat.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    final passphrase = _passphrase.text;
    String? error;
    if (name.isEmpty) {
      error = 'نام گروه را وارد کنید';
    } else if (passphrase.trim().length < _minLength) {
      error =
          'عبارت عبور باید دست‌کم ${PersianUtils.toPersianNumber('$_minLength')} نویسه باشد';
    } else if (passphrase != _repeat.text) {
      error = 'دو عبارت عبور یکسان نیستند';
    }
    setState(() => _error = error);
    if (_error == null) Navigator.of(context).pop((name, passphrase));
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: const Text('افزودن گروه'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                'همه اعضای گروه باید دقیقاً همین نام و عبارت عبور را وارد کنند. '
                'هر کس عبارت عبور را بداند می‌تواند پیام‌های گروه را بخواند و '
                'به نام هر عضو پیام بفرستد؛ امنیت گروه به اندازه قوت همین '
                'عبارت است. یک جمله طولانی و غیرقابل حدس انتخاب کنید.',
                style: TextStyle(fontSize: 13, color: scheme.onSurfaceVariant),
              ),
              const SizedBox(height: 20),
              TextField(
                controller: _name,
                decoration: const InputDecoration(labelText: 'نام گروه'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _passphrase,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(labelText: 'عبارت عبور'),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _repeat,
                obscureText: true,
                autocorrect: false,
                enableSuggestions: false,
                decoration: const InputDecoration(
                  labelText: 'تکرار عبارت عبور',
                ),
                onSubmitted: (_) => _submit(),
              ),
              if (_error != null) ...[
                const SizedBox(height: 12),
                Text(
                  _error!,
                  style: TextStyle(fontSize: 13, color: scheme.error),
                ),
              ],
            ],
          ),
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

/// "Add …" rows: the same geometry as [SettingsRow], in the primary colour so
/// they read as actions next to the rows that list what is stored.
class _ActionRow extends StatelessWidget {
  const _ActionRow({
    required this.icon,
    required this.title,
    this.summary,
    this.onTap,
  });

  final IconData icon;
  final String title;
  final String? summary;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final color = enabled
        ? scheme.primary
        : scheme.onSurface.withValues(alpha: 0.38);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Row(
          children: [
            Icon(icon, size: 24, color: color),
            const SizedBox(width: 20),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: color,
                    ),
                  ),
                  if (summary != null) ...[
                    const SizedBox(height: 2),
                    Text(
                      summary!,
                      style: TextStyle(
                        fontSize: 13,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.fromLTRB(24, 20, 24, 8),
    child: Text(
      text,
      style: TextStyle(
        fontSize: 15,
        fontWeight: FontWeight.w600,
        color: Theme.of(context).colorScheme.primary,
      ),
    ),
  );
}

Future<bool> _confirmRemove(
  BuildContext context, {
  required String title,
  required String body,
}) async {
  final scheme = Theme.of(context).colorScheme;
  final ok = await showDialog<bool>(
    context: context,
    builder: (dialogCtx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: Text(body),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(dialogCtx).pop(false),
            child: const Text('انصراف'),
          ),
          TextButton(
            style: TextButton.styleFrom(foregroundColor: scheme.error),
            onPressed: () => Navigator.of(dialogCtx).pop(true),
            child: const Text('حذف'),
          ),
        ],
      ),
    ),
  );
  return ok == true;
}

class _DirectoryRow extends StatelessWidget {
  const _DirectoryRow(this.d);
  final DirectorySummary d;

  @override
  Widget build(BuildContext context) {
    final issued = DateFormatter.formatDate(
      DateTime.fromMillisecondsSinceEpoch(d.serial),
    );
    final members = PersianUtils.toPersianNumber('${d.memberCount}');
    final own = d.hasOwnKey ? 'کلید شما: ${d.ownName}' : 'بدون کلید شما';
    return SettingsRow(
      icon: Icons.menu_book_outlined,
      title: d.name,
      summary: '$members عضو · صادرشده $issued\n$own',
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: () async {
          final bloc = context.read<KeyBankBloc>();
          if (await _confirmRemove(
            context,
            title: 'حذف دفترچه؟',
            body:
                'دفترچه «${d.name}» و کلید شما در آن از این گوشی پاک می‌شود. '
                'برای برگرداندن آن باید فایل کلید را دوباره وارد کنید.',
          )) {
            bloc.add(KeyBankRemoveDirectory(d.id));
          }
        },
      ),
    );
  }
}

class _GroupRow extends StatelessWidget {
  const _GroupRow(this.g);
  final GroupSummary g;

  @override
  Widget build(BuildContext context) {
    final code = KeyBankScreen.formatId(g.id);
    return SettingsRow(
      icon: Icons.groups_outlined,
      title: g.name,
      // LTR isolate: the code is read left to right.
      summary: 'کد گروه: \u2066$code\u2069',
      onTap: () {
        Clipboard.setData(ClipboardData(text: code));
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('کد گروه کپی شد')));
      },
      trailing: IconButton(
        icon: const Icon(Icons.delete_outline),
        tooltip: 'حذف',
        onPressed: () async {
          final bloc = context.read<KeyBankBloc>();
          if (await _confirmRemove(
            context,
            title: 'حذف گروه؟',
            body:
                'گروه «${g.name}» از این گوشی پاک می‌شود. برای برگرداندن آن '
                'باید نام و عبارت عبور را دوباره وارد کنید.',
          )) {
            bloc.add(KeyBankRemoveGroup(g.id));
          }
        },
      ),
    );
  }
}

class _NumberRow extends StatelessWidget {
  const _NumberRow(this.phone);
  final String phone;

  @override
  Widget build(BuildContext context) => SettingsRow(
    icon: Icons.sim_card_outlined,
    title: PersianUtils.displayPhone(phone),
    trailing: IconButton(
      icon: const Icon(Icons.delete_outline),
      tooltip: 'حذف',
      onPressed: () =>
          context.read<KeyBankBloc>().add(KeyBankRemoveOwnNumber(phone)),
    ),
  );
}
