import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' as device_contacts;

import 'package:communication_super_app/core/widgets/contact_numbers_line.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';

import '../models/contact_model.dart';
import '../services/contact_groups_service.dart';
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

/// The contacts carrying one label.
class _LabelMembersScreen extends StatefulWidget {
  final ContactLabel label;
  const _LabelMembersScreen({required this.label});

  @override
  State<_LabelMembersScreen> createState() => _LabelMembersScreenState();
}

class _LabelMembersScreenState extends State<_LabelMembersScreen> {
  late final Future<List<device_contacts.Contact>> _members =
      ContactGroupsService.instance.membersOf(widget.label);

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: RtlAppBar(title: widget.label.name),
        body: FutureBuilder<List<device_contacts.Contact>>(
          future: _members,
          builder: (context, snapshot) {
            if (!snapshot.hasData) {
              return const Center(child: CircularProgressIndicator());
            }
            final members = snapshot.data!;
            if (members.isEmpty) {
              return const EmptyState(
                icon: Icons.label_outline,
                title: 'کسی با این برچسب نیست',
                subtitle:
                    'از صفحهٔ ویرایش هر مخاطب می‌توانید این برچسب را به او بدهید',
              );
            }
            return ListView.builder(
              itemCount: members.length,
              itemBuilder: (context, i) => _row(context, members[i]),
            );
          },
        ),
      ),
    );
  }

  Widget _row(BuildContext context, device_contacts.Contact contact) {
    final numbers = [for (final p in contact.phones) p.number];
    final name = contact.displayName;
    return ListTile(
      leading: LazyContactAvatar(contactId: contact.id, name: name, size: 40),
      title: Text(name),
      subtitle: numbers.isEmpty
          ? null
          : Padding(
              padding: const EdgeInsets.only(top: 3),
              child: ContactNumbersLine(numbers: numbers),
            ),
      onTap: () {
        final now = DateTime.now();
        Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DeviceContactDetailScreen(
              // The detail page re-reads the contact by id; this carries only
              // what it needs to render its header before that lands.
              contact: ContactModel(
                id: contact.id,
                name: name,
                phoneNumber: numbers.isEmpty ? '' : numbers.first,
                phoneNumbers: numbers,
                createdAt: now,
                updatedAt: now,
              ),
            ),
          ),
        );
      },
    );
  }
}
