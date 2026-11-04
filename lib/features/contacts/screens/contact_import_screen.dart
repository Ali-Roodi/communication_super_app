import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/search_text.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../models/contact_save_target.dart';
import '../models/vcf_file.dart';
import '../repositories/contact_repository.dart';
import '../services/contact_file_service.dart';
import '../widgets/save_target_sheet.dart';

/// Lists what a `.vcf` file holds so the user can take all or part of it.
///
/// A contact whose number the address book already has starts unticked: taking
/// it again is a choice, and «مخاطب‌های تکراری» merges it afterwards.
class ContactImportScreen extends StatefulWidget {
  const ContactImportScreen({
    super.key,
    required this.contacts,
    required this.unreadable,
    this.service = const ContactFileService(),
  });

  final List<Contact> contacts;
  final int unreadable;
  final ContactFileService service;

  @override
  State<ContactImportScreen> createState() => _ContactImportScreenState();
}

class _ContactImportScreenState extends State<ContactImportScreen> {
  List<bool> _duplicate = const [];
  final Set<int> _chosen = {};
  List<ContactSaveTarget> _targets = const [ContactSaveTarget.phone()];
  ContactSaveTarget _target = const ContactSaveTarget.phone();
  bool _loading = true;

  /// How many have been handled while writing; null when not writing.
  int? _written;
  int _total = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final known = await ContactRepository().getAllContacts();
    final numbers = <String>{};
    final names = <String>{};
    for (final contact in known) {
      for (final phone in {contact.phoneNumber, ...contact.phoneNumbers}) {
        final key = PhoneNormalizer.toThreadId(phone);
        if (key.isNotEmpty) numbers.add(key);
      }
      names.add(SearchText.foldTight(contact.name));
    }
    final duplicate = VcfFile.duplicates(
      widget.contacts,
      knownNumbers: numbers,
      knownNames: names,
    );
    final targets = await widget.service.targets();
    final target = await widget.service.defaultTarget(targets);
    if (!mounted) return;
    setState(() {
      _duplicate = duplicate;
      _chosen
        ..clear()
        ..addAll([
          for (var i = 0; i < duplicate.length; i++)
            if (!duplicate[i]) i,
        ]);
      _targets = targets;
      _target = target;
      _loading = false;
    });
  }

  Future<void> _pickTarget() async {
    final chosen = await showSaveTargetSheet(
      context,
      targets: _targets,
      selected: _target,
    );
    if (chosen != null && mounted) setState(() => _target = chosen);
  }

  Future<void> _import() async {
    final picked = _chosen.toList()..sort();
    setState(() {
      _written = 0;
      _total = picked.length;
    });
    var done = 0;
    var failed = 0;
    for (final index in picked) {
      try {
        if (await widget.service.insert(widget.contacts[index], _target)) {
          done++;
        } else {
          failed++;
        }
      } catch (e) {
        debugPrint('contact import failed: ${e.runtimeType}');
        failed++;
      }
      if (mounted) setState(() => _written = done + failed);
    }
    ContactRepository().invalidateCache();
    LazyContactAvatar.invalidateCache();
    if (!mounted) return;
    context.read<ContactBloc>().add(const RefreshContacts());
    final messenger = ScaffoldMessenger.of(context);
    Navigator.of(context).pop();
    final tail = failed == 0
        ? ''
        : '، ${PersianUtils.toPersianNumber('$failed')} مخاطب ناموفق';
    messenger.showSnackBar(
      SnackBar(
        content: Text(
          '${PersianUtils.toPersianNumber('$done')} مخاطب اضافه شد$tail',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final count = widget.contacts.length;
    final allChosen = _chosen.length == count;
    return Directionality(
      textDirection: TextDirection.rtl,
      child: PopScope(
        canPop: _written == null,
        child: Scaffold(
          appBar: RtlAppBar(
            title: 'افزودن از فایل',
            actions: [
              if (!_loading && _written == null)
                TextButton(
                  onPressed: () => setState(() {
                    _chosen.clear();
                    if (!allChosen) {
                      _chosen.addAll(List.generate(count, (i) => i));
                    }
                  }),
                  child: Text(allChosen ? 'هیچ‌کدام' : 'انتخاب همه'),
                ),
            ],
          ),
          body: _loading ? const SizedBox.shrink() : _body(),
          bottomNavigationBar: _loading ? null : _footer(),
        ),
      ),
    );
  }

  Widget _body() {
    final skipped = widget.unreadable;
    return Column(
      children: [
        ListTile(
          leading: Icon(saveTargetIcon(_target)),
          title: const Text('ذخیره در'),
          subtitle: Text(saveTargetLabel(_target)),
          trailing: _targets.length > 1
              ? const Icon(Icons.arrow_drop_down)
              : null,
          onTap: _targets.length > 1 && _written == null ? _pickTarget : null,
        ),
        if (skipped > 0)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: AlignmentDirectional.centerStart,
              child: Text(
                '${PersianUtils.toPersianNumber('$skipped')} مورد از فایل '
                'خوانده نشد',
                style: Theme.of(context).textTheme.bodySmall,
              ),
            ),
          ),
        const Divider(height: 1),
        Expanded(
          child: ListView.builder(
            itemCount: widget.contacts.length,
            itemBuilder: (_, index) => _row(index),
          ),
        ),
      ],
    );
  }

  Widget _row(int index) {
    final contact = widget.contacts[index];
    final number = contact.phones.isEmpty ? null : contact.phones.first.number;
    final email = contact.emails.isEmpty ? null : contact.emails.first.address;
    final detail = number ?? email ?? '';
    return CheckboxListTile(
      value: _chosen.contains(index),
      onChanged: _written != null
          ? null
          : (on) => setState(() {
              on == true ? _chosen.add(index) : _chosen.remove(index);
            }),
      controlAffinity: ListTileControlAffinity.leading,
      title: Text(
        contact.displayName.isEmpty ? 'بدون نام' : contact.displayName,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
      subtitle: Text(
        _duplicate[index] ? '$detail · تکراری' : detail,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      ),
    );
  }

  Widget _footer() {
    final written = _written;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: written != null
            ? Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  LinearProgressIndicator(
                    value: _total == 0 ? null : written / _total,
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '${PersianUtils.toPersianNumber('$written')} از '
                    '${PersianUtils.toPersianNumber('$_total')}',
                  ),
                ],
              )
            : FilledButton(
                onPressed: _chosen.isEmpty ? null : _import,
                child: Text(
                  'افزودن ${PersianUtils.toPersianNumber('${_chosen.length}')} '
                  'مخاطب',
                ),
              ),
      ),
    );
  }
}
