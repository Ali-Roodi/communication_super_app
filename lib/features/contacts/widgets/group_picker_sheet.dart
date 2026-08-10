import 'package:flutter/material.dart';
import 'package:flutter_contacts/flutter_contacts.dart' show Group;

import '../services/contact_groups_service.dart';

/// The «برچسب‌ها» sheet: tick the labels a contact carries, and make a new one
/// without leaving the editor.
///
/// Creating in place is the point. A label that can only be made on a separate
/// screen means abandoning a half-typed contact to go and make it — which is
/// part of why labels stayed read-only and unused.
///
/// Returns the groups to write on the contact, or null when dismissed. Groups,
/// not labels: the contact is tagged in one specific account, and
/// [ContactGroupsService.groupFor] keeps it there.
Future<List<Group>?> showGroupPickerSheet(
  BuildContext context, {
  required List<Group> selected,
}) {
  return showModalBottomSheet<List<Group>>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (_) => _GroupPickerSheet(initial: selected),
  );
}

class _GroupPickerSheet extends StatefulWidget {
  final List<Group> initial;
  const _GroupPickerSheet({required this.initial});

  @override
  State<_GroupPickerSheet> createState() => _GroupPickerSheetState();
}

class _GroupPickerSheetState extends State<_GroupPickerSheet> {
  final _service = ContactGroupsService.instance;

  /// Names, not ids: one row on screen can stand for the same label in several
  /// accounts, and a rename must not deselect it.
  final Set<String> _selected = {};

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
      if (_loading) {
        final carried = {for (final g in widget.initial) g.id};
        _selected.addAll(
          labels.where((l) => l.ids.any(carried.contains)).map((l) => l.name),
        );
      }
      _loading = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: SizedBox(
        height: MediaQuery.of(context).size.height * 0.6,
        child: Column(
          children: [
            ListTile(
              title: const Text('برچسب‌ها'),
              trailing: TextButton(
                onPressed: _confirm,
                child: const Text('تأیید'),
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: _loading
                  ? const Center(child: CircularProgressIndicator())
                  : ListView(
                      children: [
                        for (final label in _labels)
                          CheckboxListTile(
                            value: _selected.contains(label.name),
                            title: Text(label.name),
                            secondary: IconButton(
                              icon: const Icon(Icons.more_vert),
                              tooltip: 'گزینه‌ها',
                              onPressed: () => _labelMenu(label),
                            ),
                            onChanged: (on) => setState(() {
                              if (on == true) {
                                _selected.add(label.name);
                              } else {
                                _selected.remove(label.name);
                              }
                            }),
                          ),
                        ListTile(
                          leading: const Icon(Icons.add),
                          title: const Text('ساخت برچسب جدید'),
                          onTap: _createLabel,
                        ),
                      ],
                    ),
            ),
          ],
        ),
      ),
    );
  }

  void _confirm() {
    Navigator.of(context).pop([
      for (final label in _labels)
        if (_selected.contains(label.name))
          _service.groupFor(label, existing: widget.initial),
    ]);
  }

  Future<void> _labelMenu(ContactLabel label) async {
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
                // Said out loud because it is the question everyone has: a
                // label is a tag, and removing it does not remove anyone.
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
      if (name == null) return;
      if (await _service.rename(label, name)) {
        if (_selected.remove(label.name)) _selected.add(name);
      }
    } else {
      await _service.delete(label);
      _selected.remove(label.name);
    }
    await _load(force: true);
  }

  Future<void> _createLabel() async {
    final name = await askLabelName(context, title: 'برچسب جدید');
    if (name == null) return;
    final created = await _service.create(name);
    if (created != null) _selected.add(created.name);
    await _load(force: true);
  }
}

/// The one-field dialog behind «برچسب جدید» / «تغییر نام», shared with the
/// labels screen so the two never word the same question differently.
Future<String?> askLabelName(
  BuildContext context, {
  String initial = '',
  required String title,
}) {
  final controller = TextEditingController(text: initial);
  return showDialog<String>(
    context: context,
    builder: (ctx) => Directionality(
      textDirection: TextDirection.rtl,
      child: AlertDialog(
        title: Text(title),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(labelText: 'نام برچسب'),
          onSubmitted: (v) => Navigator.of(ctx).pop(v.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('انصراف'),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(controller.text.trim()),
            child: const Text('ذخیره'),
          ),
        ],
      ),
    ),
  ).then((value) => (value == null || value.isEmpty) ? null : value);
}
