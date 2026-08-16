import 'package:flutter/material.dart';

import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/messages/screens/broadcast_compose_screen.dart';

import '../models/contact_model.dart';
import '../repositories/contact_repository.dart';
import '../services/contact_groups_service.dart';
import '../widgets/contact_picker_sheet.dart';
import '../widgets/group_picker_sheet.dart';
import 'device_contact_detail_screen.dart';

/// «برچسب‌ها» — the device's contact labels, and who carries each.
///
/// The labels themselves already existed in the address book and the app could
/// only *display* them on a contact page. This is the other half: make one,
/// rename it, delete it, and see its members.
class ContactLabelsScreen extends StatefulWidget {
  const ContactLabelsScreen({super.key});

  @override
  State<ContactLabelsScreen> createState() => _ContactLabelsScreenState();
}

class _ContactLabelsScreenState extends State<ContactLabelsScreen> {
  final _service = ContactGroupsService.instance;
  List<ContactLabel> _labels = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load({bool force = false}) async {
    final labels = await _service.getLabels(forceRefresh: force);
    if (!mounted) return;
    setState(() {
      _labels = labels;
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: const RtlAppBar(title: 'برچسب‌ها'),
        floatingActionButton: FloatingActionButton(
          heroTag: 'labels_fab',
          tooltip: 'برچسب جدید',
          onPressed: _create,
          child: const Icon(Icons.add),
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _labels.isEmpty
            ? const EmptyState(
                icon: Icons.label_outline,
                title: 'برچسبی ندارید',
                subtitle:
                    'با برچسب می‌توانید مخاطبین را دسته‌بندی کنید — مثل «خانواده» یا «کار»',
              )
            : ListView(
                padding: const EdgeInsets.only(bottom: 96),
                children: [
                  for (final label in _labels)
                    ListTile(
                      leading: const Icon(Icons.label_outline),
                      title: Text(label.name),
                      trailing: IconButton(
                        icon: const Icon(Icons.more_vert),
                        tooltip: 'گزینه‌ها',
                        onPressed: () => _menu(label),
                      ),
                      onTap: () => Navigator.of(context).push(
                        MaterialPageRoute(
                          builder: (_) => _LabelMembersScreen(label: label),
                        ),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Future<void> _menu(ContactLabel label) async {
    final action = await showModalBottomSheet<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.edit_outlined),
                title: const Text('تغییر نام'),
                onTap: () => Navigator.of(ctx).pop('rename'),
              ),
              ListTile(
                leading: const Icon(Icons.delete_outline),
                title: const Text('حذف برچسب'),
                subtitle: const Text('مخاطبین حذف نمی‌شوند'),
                onTap: () => Navigator.of(ctx).pop('delete'),
              ),
            ],
          ),
        ),
      ),
    );
    if (action == null || !mounted) return;
    if (action == 'rename') {
      final name = await askLabelName(
        context,
        initial: label.name,
        title: 'تغییر نام برچسب',
      );
      if (name != null) await _service.rename(label, name);
    } else {
      // Asked, because it cannot be undone: the label's membership rows go with
      // it, and re-creating the name does not bring anybody back.
      final confirmed = await showDialog<bool>(
        context: context,
        builder: (ctx) => Directionality(
          textDirection: TextDirection.rtl,
          child: AlertDialog(
            title: Text('حذف «${label.name}»؟'),
            content: const Text(
              'برچسب حذف می‌شود و از روی مخاطبین برداشته می‌شود. خود مخاطبین حذف نمی‌شوند.',
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(false),
                child: const Text('انصراف'),
              ),
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(true),
                child: const Text('حذف'),
              ),
            ],
          ),
        ),
      );
      if (confirmed != true) return;
      await _service.delete(label);
    }
    await _load(force: true);
  }

  Future<void> _create() async {
    final name = await askLabelName(context, title: 'برچسب جدید');
    if (name == null) return;
    await _service.create(name);
    await _load(force: true);
  }
}

/// The contacts carrying one label — and the two things anyone opens a label
/// for: adding someone to it, and writing to everyone in it.
class _LabelMembersScreen extends StatefulWidget {
  final ContactLabel label;
  const _LabelMembersScreen({required this.label});

  @override
  State<_LabelMembersScreen> createState() => _LabelMembersScreenState();
}

class _LabelMembersScreenState extends State<_LabelMembersScreen> {
  List<ContactModel> _members = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  /// Members are read as **ids from the Data table** and resolved against the
  /// contact cache the rest of the app already holds.
  ///
  /// The old version pulled the entire address book with `withGroups: true`
  /// just to filter it in Dart — a second full read of every contact on the
  /// phone, for a screen that shows a handful of them.
  Future<void> _load() async {
    final ids = await ContactGroupsService.instance.memberIds(widget.label);
    // Null means the native side did not answer — fall back to the full read
    // rather than claiming the label is empty, which is the one wrong answer
    // this screen can give.
    final wanted =
        ids?.toSet() ??
        (await ContactGroupsService.instance.membersOf(
          widget.label,
        )).map((c) => c.id).toSet();
    final contacts = await ContactRepository().getAllContacts();
    if (!mounted) return;
    setState(() {
      _members = [
        for (final c in contacts)
          if (wanted.contains(c.id)) c,
      ];
      _loading = false;
    });
  }

  Future<void> _addContacts() async {
    // The picker returns one contact at a time; adding several is a matter of
    // opening it again, which is also how Google Contacts does it.
    final picked = await showContactPickerSheet(
      context,
      title: 'افزودن به «${widget.label.name}»',
    );
    if (picked == null || !mounted) return;
    final added = await ContactGroupsService.instance.addToLabel(
      widget.label.name,
      [picked.contact.id],
    );
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          added > 0
              ? '${picked.contact.name} به «${widget.label.name}» افزوده شد'
              : 'افزودن ممکن نشد',
        ),
      ),
    );
    await _load();
  }

  Future<void> _remove(ContactModel contact) async {
    await ContactGroupsService.instance.removeFromLabel(widget.label.name, [
      contact.id,
    ]);
    if (!mounted) return;
    await _load();
  }

  /// «پیامک گروهی» — one message to everyone carrying the label.
  ///
  /// Recipients are the members' first numbers; anyone without a number is
  /// simply not a recipient (and is reported, so the count on the next screen
  /// is not a surprise).
  Future<void> _messageAll() async {
    final recipients = <BroadcastRecipient>[];
    var skipped = 0;
    for (final contact in _members) {
      final number = contact.phoneNumbers.isNotEmpty
          ? contact.phoneNumbers.first
          : contact.phoneNumber;
      if (number.isEmpty) {
        skipped++;
        continue;
      }
      recipients.add(
        BroadcastRecipient(phoneNumber: number, name: contact.name),
      );
    }
    if (recipients.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('هیچ‌کدام شماره‌ای ندارند')));
      return;
    }
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            '${PersianUtils.toPersianNumber('$skipped')} مخاطب بدون شماره کنار گذاشته شد',
          ),
        ),
      );
    }
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => BroadcastComposeScreen(
          recipients: recipients,
          title: 'پیام به «${widget.label.name}»',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(
          title: widget.label.name,
          actions: [
            IconButton(
              icon: const Icon(Icons.sms_outlined),
              tooltip: 'پیامک گروهی',
              onPressed: _members.isEmpty ? null : _messageAll,
            ),
            IconButton(
              icon: const Icon(Icons.person_add_alt),
              tooltip: 'افزودن مخاطب',
              onPressed: _addContacts,
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : _members.isEmpty
            ? const EmptyState(
                icon: Icons.label_outline,
                title: 'کسی با این برچسب نیست',
                subtitle:
                    'با «افزودن مخاطب» در بالای صفحه، یا از صفحهٔ ویرایش هر مخاطب',
              )
            : ListView.builder(
                itemCount: _members.length,
                itemBuilder: (context, i) => _row(context, _members[i]),
              ),
      ),
    );
  }

  Widget _row(BuildContext context, ContactModel contact) {
    return ListTile(
      leading: LazyContactAvatar(
        contactId: contact.id,
        name: contact.name,
        size: 40,
      ),
      title: Text(contact.name),
      subtitle: contact.phoneNumbers.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: ContactNumbersLine(numbers: contact.phoneNumbers),
            ),
      trailing: IconButton(
        icon: const Icon(Icons.remove_circle_outline),
        tooltip: 'حذف از برچسب',
        onPressed: () => _remove(contact),
      ),
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => DeviceContactDetailScreen(contact: contact),
        ),
      ),
    );
  }
}
