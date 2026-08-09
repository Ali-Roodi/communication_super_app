import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import '../conversation_screen.dart';

/// What to do with a phone number tapped inside a message: call it, text it,
/// open the contact it belongs to (or save it), or copy it.
///
/// This replaces launching a `tel:` intent. As the default dialer, the app is
/// itself the target of `tel:` — the launch bounced back into this process,
/// froze the UI for several seconds and could take the activity down with it.
/// Everything here stays in-process.
Future<void> showPhoneActionSheet(BuildContext context, String rawNumber) {
  final number = PhoneNormalizer.toNational(rawNumber);
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    builder: (sheetContext) => _PhoneActionSheet(number: number),
  );
}

class _PhoneActionSheet extends StatefulWidget {
  final String number;
  const _PhoneActionSheet({required this.number});

  @override
  State<_PhoneActionSheet> createState() => _PhoneActionSheetState();
}

class _PhoneActionSheetState extends State<_PhoneActionSheet> {
  /// Resolved asynchronously: on a cold cache this walks the address book, and
  /// the sheet must be on screen instantly either way.
  ContactModel? _contact;
  bool _resolving = true;

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  Future<void> _resolve() async {
    ContactModel? match;
    try {
      match = await ContactRepository().getContactByPhoneNumber(widget.number);
    } catch (_) {
      // No contacts permission (or no address book at all) — the sheet still
      // has to offer call / SMS / save.
      match = null;
    }
    if (!mounted) return;
    setState(() {
      _contact = match;
      _resolving = false;
    });
  }

  /// Closes the sheet, then runs [action] against the page underneath.
  void _pop(void Function(BuildContext pageContext) action) {
    final pageContext = Navigator.of(context).context;
    Navigator.of(context).pop();
    action(pageContext);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final name = _contact?.name;
    final display = PersianUtils.displayPhone(widget.number);

    return Directionality(
      textDirection: TextDirection.rtl,
      child: SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              // The sheet already resolves the contact for its «مشاهده مخاطب»
              // row, so it feeds LazyContactAvatar directly instead of going
              // through PhoneContactAvatar — same photo, one lookup. An empty
              // id (still resolving, or unsaved number) falls back to initials.
              leading: LazyContactAvatar(
                contactId: _contact?.id ?? '',
                name: name ?? display,
                size: 44,
              ),
              title: Text(
                name ?? display,
                style: theme.textTheme.titleMedium,
              ),
              subtitle: name == null
                  ? null
                  : Directionality(
                      textDirection: TextDirection.ltr,
                      child: Text(display, textAlign: TextAlign.right),
                    ),
            ),
            const Divider(height: 1),
            ListTile(
              leading: const Icon(Icons.call_outlined),
              title: const Text('تماس'),
              onTap: () => _pop(
                (_) => NativeCallService.instance.makeCall(widget.number),
              ),
            ),
            ListTile(
              leading: const Icon(Icons.message_outlined),
              title: const Text('ارسال پیامک'),
              onTap: () => _pop(
                (pageContext) => Navigator.of(pageContext).push(
                  MaterialPageRoute(
                    builder: (_) => ConversationScreen.forPhone(
                      widget.number,
                      contactName: name,
                    ),
                  ),
                ),
              ),
            ),
            // Until the lookup lands the row would flip under the user's
            // finger, so it stays disabled with a spinner instead.
            if (_resolving)
              const ListTile(
                leading: SizedBox(
                  width: 24,
                  height: 24,
                  child: Center(
                    child: SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
                ),
                title: Text('در حال جستجوی مخاطب…'),
                enabled: false,
              )
            else if (_contact != null)
              ListTile(
                leading: const Icon(Icons.person_outline),
                title: const Text('مشاهده مخاطب'),
                onTap: () => _pop(
                  (pageContext) => Navigator.of(pageContext).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          DeviceContactDetailScreen(contact: _contact!),
                    ),
                  ),
                ),
              )
            else
              ListTile(
                leading: const Icon(Icons.person_add_alt),
                title: const Text('افزودن به مخاطبین'),
                onTap: () => _pop(
                  (pageContext) => Navigator.of(pageContext).push(
                    MaterialPageRoute(
                      builder: (_) =>
                          AddEditContactScreen(initialPhone: widget.number),
                    ),
                  ),
                ),
              ),
            ListTile(
              leading: const Icon(Icons.copy_outlined),
              title: const Text('کپی شماره'),
              onTap: () => _pop((pageContext) {
                Clipboard.setData(ClipboardData(text: widget.number));
                ScaffoldMessenger.of(
                  pageContext,
                ).showSnackBar(const SnackBar(content: Text('کپی شد')));
              }),
            ),
          ],
        ),
      ),
    );
  }
}
