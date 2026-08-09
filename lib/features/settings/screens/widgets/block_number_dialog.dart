import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/undo_snack_bar.dart';
import '../../bloc/blocked_numbers_bloc.dart';
import '../../models/blocked_number_model.dart';

/// The one confirmation the whole app uses before blocking a number.
///
/// Google Messages and Google Phone ask once and fold the spam report into that
/// same question as a checkbox — «مسدود کردن و گزارش هرزنامه» is one gesture,
/// not two menu items — because a user who wants nothing more from a number
/// almost always also wants it reported, and being asked twice reads as a
/// system that did not understand the first answer.
///
/// The checkbox defaults to on for a number the user has no contact for, and off
/// for a saved contact: reporting someone in your own address book as spam is
/// nearly always a mis-tap.
Future<BlockDecision?> showBlockNumberDialog(
  BuildContext context, {
  required String phoneNumber,
  String? contactName,
  int numberCount = 1,
}) {
  final hasName = contactName != null && contactName.trim().isNotEmpty;
  final subject = numberCount > 1
      ? '${PersianUtils.toPersianNumber('$numberCount')} شماره'
      : hasName
      ? contactName.trim()
      : PersianUtils.displayPhone(PhoneNormalizer.toNational(phoneNumber));

  return showDialog<BlockDecision>(
    context: context,
    builder: (dialogContext) => _BlockNumberDialog(
      subject: subject,
      plural: numberCount > 1,
      reportByDefault: !hasName,
    ),
  );
}

/// Ask, block, confirm with an undo — the whole gesture, so every entry point
/// (conversation menu, call-log row, call details, contact page, inbox
/// selection) behaves identically instead of each re-implementing it and
/// drifting.
///
/// [onBlocked] runs only if the user went through with it, for callers that have
/// to refresh something afterwards (the inbox hides blocked threads, so it
/// reloads). It runs again on undo, since the same thing has to be refreshed.
Future<bool> blockNumberWithConfirm(
  BuildContext context, {
  required String phoneNumber,
  String? contactName,
  VoidCallback? onBlocked,
}) async {
  final decision = await showBlockNumberDialog(
    context,
    phoneNumber: phoneNumber,
    contactName: contactName,
  );
  if (decision == null || !context.mounted) return false;

  final bloc = context.read<BlockedNumbersBloc>();
  bloc.add(BlockNumber(phoneNumber, report: decision.report));
  onBlocked?.call();

  final label = (contactName != null && contactName.trim().isNotEmpty)
      ? contactName.trim()
      : PersianUtils.displayPhone(PhoneNormalizer.toNational(phoneNumber));
  showUndoSnack(
    context,
    message: decision.report
        ? '«$label» مسدود و به‌عنوان هرزنامه گزارش شد'
        : '«$label» مسدود شد',
    onUndo: () {
      bloc.add(UnblockNumber(BlockedNumberModel.normalize(phoneNumber)));
      onBlocked?.call();
    },
  );
  return true;
}

/// What the user chose. Null (no decision) means they backed out.
class BlockDecision {
  /// Whether «گزارش به‌عنوان هرزنامه» was left ticked.
  final bool report;
  const BlockDecision({required this.report});
}

class _BlockNumberDialog extends StatefulWidget {
  const _BlockNumberDialog({
    required this.subject,
    required this.plural,
    required this.reportByDefault,
  });

  final String subject;
  final bool plural;
  final bool reportByDefault;

  @override
  State<_BlockNumberDialog> createState() => _BlockNumberDialogState();
}

class _BlockNumberDialogState extends State<_BlockNumberDialog> {
  late bool _report = widget.reportByDefault;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text('«${widget.subject}» مسدود شود؟'),
        content: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              widget.plural
                  ? 'دیگر پیامک و تماسی از این شماره‌ها دریافت نمی‌کنید و '
                        'گفتگوهایشان به «هرزنامه و مسدودشده» منتقل می‌شود.'
                  : 'دیگر پیامک و تماسی از این شماره دریافت نمی‌کنید و گفتگوی '
                        'آن به «هرزنامه و مسدودشده» منتقل می‌شود.',
              style: theme.textTheme.bodyMedium,
            ),
            const SizedBox(height: 8),
            // A tappable row, not a bare Checkbox: the label is the target the
            // thumb actually lands on.
            InkWell(
              onTap: () => setState(() => _report = !_report),
              borderRadius: BorderRadius.circular(8),
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 4),
                child: Row(
                  children: [
                    Checkbox(
                      value: _report,
                      onChanged: (v) => setState(() => _report = v ?? false),
                      visualDensity: VisualDensity.compact,
                    ),
                    const SizedBox(width: 4),
                    Expanded(
                      child: Text(
                        'گزارش به‌عنوان هرزنامه',
                        style: theme.textTheme.bodyMedium,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () =>
                Navigator.pop(context, BlockDecision(report: _report)),
            child: Text(
              _report ? 'مسدود و گزارش' : 'مسدود کردن',
              style: const TextStyle(color: AppColors.danger),
            ),
          ),
        ],
      ),
    );
  }
}
