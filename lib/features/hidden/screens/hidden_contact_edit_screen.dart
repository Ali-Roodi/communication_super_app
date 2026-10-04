import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;
import 'package:uuid/uuid.dart';

import 'package:communication_super_app/core/services/app_handoff.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/services/sim_contacts_service.dart';
import 'package:communication_super_app/features/contacts/widgets/contact_picker_sheet.dart';
import 'package:communication_super_app/features/messages/services/native_sms_service.dart';

import '../bloc/hidden_bloc.dart';
import '../repositories/hidden_contacts_repository.dart';

/// Creates or edits a hidden contact. Saving a number that was not hidden
/// before moves its past SMS and calls into the secure section too.
class HiddenContactEditScreen extends StatefulWidget {
  const HiddenContactEditScreen({super.key, this.contact});

  /// Null for a new contact.
  final HiddenContact? contact;

  @override
  State<HiddenContactEditScreen> createState() =>
      _HiddenContactEditScreenState();
}

class _HiddenContactEditScreenState extends State<HiddenContactEditScreen> {
  late final String _id = widget.contact?.id ?? const Uuid().v4();
  late final _name = TextEditingController(text: widget.contact?.name);
  late final _note = TextEditingController(text: widget.contact?.note);
  late final List<TextEditingController> _numbers = [
    for (final n in widget.contact?.numbers ?? const <HiddenNumber>[])
      TextEditingController(text: n.phone),
    if (widget.contact?.numbers.isEmpty ?? true) TextEditingController(),
  ];

  /// The address-book contact this one was filled from, offered for
  /// deletion once saved.
  ContactModel? _imported;
  bool _saving = false;

  @override
  void dispose() {
    _name.dispose();
    _note.dispose();
    for (final c in _numbers) {
      c.dispose();
    }
    super.dispose();
  }

  Future<void> _import() async {
    final picked = await showContactPickerSheet(
      context,
      title: 'انتقال از دفترچه تلفن گوشی',
      pickNumber: false,
    );
    if (picked == null || !mounted) return;
    final c = picked.contact;
    setState(() {
      _imported = c;
      _name.text = c.name;
      for (final n in _numbers) {
        n.dispose();
      }
      _numbers
        ..clear()
        ..addAll([
          for (final p
              in c.phoneNumbers.isEmpty ? [c.phoneNumber] : c.phoneNumbers)
            TextEditingController(text: p),
        ]);
      if (_numbers.isEmpty) _numbers.add(TextEditingController());
    });
  }

  void _save() {
    setState(() => _saving = true);
    context.read<HiddenBloc>().add(
      HiddenSaveContact(
        id: _id,
        name: _name.text,
        numbers: [for (final c in _numbers) c.text],
        note: _note.text,
      ),
    );
  }

  Future<void> _onSaved() async {
    final imported = _imported;
    if (imported != null) await _offerDeviceDelete(imported);
    if (mounted) await _offerSmsRole();
    if (mounted) Navigator.of(context).pop();
  }

  /// Only the default SMS app may delete from the phone's SMS store: without
  /// the role this contact's past SMS stay there (hidden in هم‌رسان only),
  /// and new ones land in the other app too.
  Future<void> _offerSmsRole() async {
    final sms = NativeSmsService();
    if (await sms.isDefaultSmsApp() || !mounted) return;
    final ask = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('هم‌رسان برنامه پیش‌فرض پیامک نیست'),
          content: const Text(
            'پیامک‌های این مخاطب فقط وقتی از حافظه پیامک گوشی پاک می‌شوند و '
            'پیامک‌های تازه‌اش فقط وقتی به برنامه‌های دیگر نمی‌رسند که هم‌رسان '
            'برنامه پیش‌فرض پیامک باشد.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('بعداً'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('پیش‌فرض کردن'),
            ),
          ],
        ),
      ),
    );
    if (ask != true) return;
    // The role dialog is another app's screen: it must not close the section.
    final granted = await AppHandoff.run(sms.requestDefaultSmsRole);
    if (!granted) return;
    for (final c in _numbers) {
      final number = c.text.trim();
      if (number.isNotEmpty) await sms.deleteSmsThreadFromProvider(number);
    }
  }

  /// The copy in the phone's address book is what other apps can read; the
  /// point of hiding is lost while it stays.
  Future<void> _offerDeviceDelete(ContactModel c) async {
    final remove = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف از دفترچه تلفن گوشی؟'),
          content: Text(
            '«${c.name}» حالا در دفترچه مخفی است. تا وقتی در دفترچه تلفن گوشی '
            'هم باشد، برنامه‌های دیگر آن را می‌بینند.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('نگه دار'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف از گوشی'),
            ),
          ],
        ),
      ),
    );
    if (remove != true || !mounted) return;
    final contacts = context.read<ContactBloc>();
    final messenger = ScaffoldMessenger.of(context);
    try {
      if (c.isSimContact) {
        await SimContactsService.delete(c);
      } else {
        final full = await device_contacts.FlutterContacts.getContact(c.id);
        if (full != null) {
          await device_contacts.FlutterContacts.deleteContacts([full]);
        }
      }
      ContactRepository().invalidateCache();
      LazyContactAvatar.invalidateCache();
      contacts.add(const RefreshContacts());
    } catch (e) {
      messenger.showSnackBar(
        const SnackBar(content: Text('حذف از دفترچه تلفن گوشی ناموفق بود')),
      );
    }
  }

  String _errorText(HiddenState s) => switch (s.error) {
    HiddenSaveError.noName => 'نام را وارد کنید.',
    HiddenSaveError.noNumber => 'دست‌کم یک شماره لازم است.',
    HiddenSaveError.badNumber => '«${s.errorDetail}» شماره تلفن نیست.',
    HiddenSaveError.numberTaken =>
      'این شماره در مخاطب مخفی «${s.errorDetail}» هست.',
    null => '',
  };

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final editing = widget.contact != null;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: MultiBlocListener(
        listeners: [
          BlocListener<HiddenBloc, HiddenState>(
            listenWhen: (a, b) => a.savedSeq != b.savedSeq && b.savedId == _id,
            listener: (_, _) => _onSaved(),
          ),
          BlocListener<HiddenBloc, HiddenState>(
            listenWhen: (a, b) => a.errorSeq != b.errorSeq,
            listener: (context, state) {
              setState(() => _saving = false);
              ScaffoldMessenger.of(
                context,
              ).showSnackBar(SnackBar(content: Text(_errorText(state))));
            },
          ),
          BlocListener<HiddenBloc, HiddenState>(
            listenWhen: (a, b) => b.status == HiddenStatus.locked,
            listener: (context, _) => Navigator.of(context).pop(),
          ),
        ],
        child: Scaffold(
          appBar: RtlAppBar(
            title: editing ? 'ویرایش مخاطب مخفی' : 'مخاطب مخفی جدید',
            actions: [
              TextButton(
                onPressed: _saving ? null : _save,
                child: const Text('ذخیره'),
              ),
            ],
          ),
          body: ListView(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 32),
            children: [
              if (!editing) ...[
                OutlinedButton.icon(
                  onPressed: _saving ? null : _import,
                  icon: const Icon(Icons.move_down_outlined),
                  label: const Text('از دفترچه تلفن گوشی'),
                ),
                const SizedBox(height: 20),
              ],
              TextField(
                controller: _name,
                textInputAction: TextInputAction.next,
                decoration: const InputDecoration(
                  labelText: 'نام',
                  prefixIcon: Icon(Icons.person_outline),
                ),
              ),
              const SizedBox(height: 16),
              for (var i = 0; i < _numbers.length; i++) ...[
                Row(
                  children: [
                    Expanded(
                      child: TextField(
                        controller: _numbers[i],
                        keyboardType: TextInputType.phone,
                        textDirection: TextDirection.ltr,
                        textAlign: TextAlign.right,
                        decoration: InputDecoration(
                          labelText: i == 0
                              ? 'شماره'
                              : 'شماره ${PersianUtils.toPersianNumber('${i + 1}')}',
                          prefixIcon: const Icon(Icons.phone_outlined),
                        ),
                      ),
                    ),
                    if (_numbers.length > 1)
                      IconButton(
                        tooltip: 'حذف شماره',
                        icon: const Icon(Icons.remove_circle_outline),
                        onPressed: () =>
                            setState(() => _numbers.removeAt(i).dispose()),
                      ),
                  ],
                ),
                const SizedBox(height: 12),
              ],
              Align(
                alignment: AlignmentDirectional.centerStart,
                child: TextButton.icon(
                  onPressed: () =>
                      setState(() => _numbers.add(TextEditingController())),
                  icon: const Icon(Icons.add),
                  label: const Text('افزودن شماره'),
                ),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _note,
                minLines: 2,
                maxLines: 5,
                decoration: const InputDecoration(
                  labelText: 'یادداشت',
                  prefixIcon: Icon(Icons.notes_outlined),
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'پیامک‌ها و تماس‌های قبلی این شماره‌ها هم از سوابق گوشی به '
                'بخش امن منتقل می‌شوند. از این پس هیچ تماس یا پیامکی با آن‌ها '
                'در سوابق گوشی ثبت نمی‌شود.',
                style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
