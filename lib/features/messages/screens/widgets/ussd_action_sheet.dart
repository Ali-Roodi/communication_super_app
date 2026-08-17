import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/ussd_code.dart';

/// What to do with a USSD/MMI code tapped inside a message: dial it or copy it.
///
/// Dialling goes through [placeCall] like every other dial in the app, so the
/// SIM question is answered the same way — and it matters more here than
/// anywhere: a balance code is answered by the *carrier*, so running «*140*11#»
/// on the wrong card asks the wrong operator.
///
/// The code never leaves this app as a `tel:` intent. It is handed to telecom,
/// which recognises the MMI shape and lets telephony answer it in its own
/// dialog; `CallInCallService.onCallAdded` drops it so no call screen flashes
/// over that dialog.
Future<void> showUssdActionSheet(BuildContext context, String rawCode) {
  final code = UssdCode.toDialable(rawCode);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _UssdActionSheet(code: code),
  );
}

class _UssdActionSheet extends StatelessWidget {
  /// ASCII, dialable — `*` and `#` intact.
  final String code;

  const _UssdActionSheet({required this.code});

  /// Closes the sheet, then runs [action] against the page underneath: a
  /// snack bar or a SIM picker has to outlive this route.
  void _pop(BuildContext context, void Function(BuildContext page) action) {
    final pageContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    action(pageContext);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.dialpad),
              // The code itself, laid out left-to-right and in Persian digits
              // to match the rest of the app. LTR is not cosmetic here: this is
              // the string the user is about to dial and it must read in the
              // order it will be sent.
              title: Directionality(
                textDirection: TextDirection.ltr,
                child: Text(
                  PersianUtils.toPersianNumber(code),
                  textAlign: TextAlign.left,
                  style: theme.textTheme.titleMedium,
                ),
              ),
              subtitle: const Text('کد دستوری (USSD)'),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.call_outlined),
              title: const Text('شماره‌گیری'),
              onTap: () => _pop(context, (page) => placeCall(page, code)),
              onLongPress: SimService.isMultiSim
                  ? () =>
                        _pop(context, (page) => placeCallPickingSim(page, code))
                  : null,
            ),
            // Which carrier answers is the whole question for a USSD code, so
            // the per-SIM rows are spelled out rather than hidden behind a
            // long-press.
            ...simCallRows(
              context,
              code,
              onBeforeCall: () => Navigator.of(context).pop(),
            ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('کپی کد'),
              onTap: () => _pop(context, (page) {
                // ASCII, because it is going into another app's field or the
                // keypad — Persian digits there would be useless.
                Clipboard.setData(ClipboardData(text: code));
                ScaffoldMessenger.of(
                  page,
                ).showSnackBar(const SnackBar(content: Text('کد کپی شد')));
              }),
            ),
          ],
        ),
      ),
    );
  }
}
