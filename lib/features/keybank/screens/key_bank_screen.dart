import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/secure/repositories/key_bank_repository.dart';
import 'package:communication_super_app/features/secure/services/sms_crypto_service.dart';
import 'package:communication_super_app/features/secure/widgets/secure_locked_view.dart';

import '../bloc/key_bank_bloc.dart';
import '../services/key_file_service.dart';
import '../services/trust_anchors.dart';

/// «بانک کلید» — Settings → امنیت. Only inside an open secure section.
class KeyBankScreen extends StatelessWidget {
  const KeyBankScreen({super.key, this.keyFiles = const KeyFileService()});

  final KeyFileService keyFiles;

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
    KeyBankNotice.updateNotForThisPhone =>
      'این فایل به‌روزرسانیِ سازمانی است که در این گوشی نیست؛ اول فایل کلید خودتان را وارد کنید',
    KeyBankNotice.ownKeyRetired =>
      'دفترچه به‌روز شد، ولی کلید شما در آن عوض شده است؛ فایل کلید تازه خودتان را با رمزش وارد کنید',
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
            KeyBankStatus.locked => const SecureLockedView(
              message:
                  'بانک کلید داخل بخش امن نگهداری می‌شود. برای دیدن یا تغییر '
                  'آن، بخش امن را باز کنید.',
            ),
            KeyBankStatus.loading => const SizedBox.shrink(),
            KeyBankStatus.ready => _Bank(state: state, keyFiles: keyFiles),
          },
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
              summary:
                  'فایل کلید شما، یا فایل به‌روزرسانی (update.hku) که مرجع سازمان فرستاده',
              onTap: state.busy ? null : () => _importFile(context),
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
    // An update file carries no key of ours and is opened without asking
    // anything: only a phone of that organization can open it.
    if (SmsCryptoService.isUpdateFile(file)) {
      bloc.add(KeyBankImportUpdate(file));
      return;
    }
    final password = await _askText(
      context,
      title: 'رمز فایل کلید',
      hint: 'XXXX-XXXX-XXXX-XXXX-XXXX',
      latin: true,
    );
    if (password == null) return;
    if (password.trim().isEmpty) {
      messenger.showSnackBar(
        const SnackBar(content: Text('رمز فایل کلید را وارد کنید')),
      );
      return;
    }
    bloc.add(KeyBankImportFile(file, password));
  }
}

Future<String?> _askText(
  BuildContext context, {
  required String title,
  required String hint,
  bool latin = false,
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
          keyboardType: TextInputType.visiblePassword,
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
