import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/services/image_picker_service.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../models/contact_form_entries.dart';
import '../repositories/contact_repository.dart';
import 'widgets/contact_form_fields.dart';

/// Full-screen Add / Edit contact form. Writes to the **device** contacts
/// (flutter_contacts) so changes appear everywhere (list, favorites, dialer).
///
/// [contactId] is a device contact id (edit mode); [initialPhone] pre-fills the
/// first phone when creating.
class AddEditContactScreen extends StatefulWidget {
  final String? contactId;
  final String? initialPhone;

  const AddEditContactScreen({super.key, this.contactId, this.initialPhone});

  @override
  State<AddEditContactScreen> createState() => _AddEditContactScreenState();
}

class _AddEditContactScreenState extends State<AddEditContactScreen> {
  final _formKey = GlobalKey<FormState>();

  final _firstName = TextEditingController();
  final _lastName = TextEditingController();
  final _address = TextEditingController();
  final _company = TextEditingController();
  final _notes = TextEditingController();
  final _nickname = TextEditingController();
  final _website = TextEditingController();

  final List<PhoneEntry> _phones = [];
  final List<EmailEntry> _emails = [];
  DateTime? _birthday;

  Contact? _editing; // populated in edit mode
  Uint8List? _photo; // selected/loaded profile photo
  bool _loading = false;
  bool _saving = false;
  bool _showMore = false;

  bool get _isEdit => widget.contactId != null;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      _loadContact();
    } else {
      _phones.add(PhoneEntry(text: widget.initialPhone ?? ''));
    }
  }

  @override
  void dispose() {
    _firstName.dispose();
    _lastName.dispose();
    _address.dispose();
    _company.dispose();
    _notes.dispose();
    _nickname.dispose();
    _website.dispose();
    for (final p in _phones) {
      p.controller.dispose();
    }
    for (final e in _emails) {
      e.controller.dispose();
    }
    super.dispose();
  }

  Future<void> _loadContact() async {
    setState(() => _loading = true);
    final c = await FlutterContacts.getContact(
      widget.contactId!,
      withProperties: true,
      withPhoto: true,
      withAccounts: true,
    );
    if (c == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _editing = c;
    _photo = c.photo;
    _firstName.text = c.name.first;
    _lastName.text = c.name.last;
    _nickname.text = c.name.nickname;
    for (final p in c.phones) {
      // Coerce labels outside our dropdown set so DropdownButton has a match.
      final label = kPhoneLabels.containsKey(p.label)
          ? p.label
          : PhoneLabel.other;
      _phones.add(PhoneEntry(text: p.number, label: label));
    }
    if (_phones.isEmpty) _phones.add(PhoneEntry());
    for (final e in c.emails) {
      final label = kEmailLabels.containsKey(e.label)
          ? e.label
          : EmailLabel.other;
      _emails.add(EmailEntry(text: e.address, label: label));
    }
    if (c.addresses.isNotEmpty) _address.text = c.addresses.first.address;
    if (c.organizations.isNotEmpty) {
      _company.text = c.organizations.first.company;
    }
    if (c.notes.isNotEmpty) _notes.text = c.notes.first.note;
    if (c.websites.isNotEmpty) _website.text = c.websites.first.url;
    final bday = c.events.where((e) => e.label == EventLabel.birthday);
    if (bday.isNotEmpty) {
      final e = bday.first;
      _birthday = DateTime(e.year ?? 2000, e.month, e.day);
    }
    if (mounted) setState(() => _loading = false);
  }

  // ── Save / delete ─────────────────────────────────────────────────────────

  Future<void> _save() async {
    if (!_formKey.currentState!.validate()) return;
    setState(() => _saving = true);
    try {
      if (!await FlutterContacts.requestPermission(readonly: false)) {
        _snack('دسترسی به مخاطبین داده نشد');
        setState(() => _saving = false);
        return;
      }

      final contact = _editing ?? Contact();
      contact.photo = _photo;
      contact.name = Name(
        first: _firstName.text.trim(),
        last: _lastName.text.trim(),
        nickname: _nickname.text.trim(),
      );
      contact.phones = _phones
          .where((p) => p.controller.text.trim().isNotEmpty)
          .map((p) => Phone(p.controller.text.trim(), label: p.label))
          .toList();
      contact.emails = _emails
          .where((e) => e.controller.text.trim().isNotEmpty)
          .map((e) => Email(e.controller.text.trim(), label: e.label))
          .toList();
      contact.addresses = _address.text.trim().isEmpty
          ? []
          : [Address(_address.text.trim(), label: AddressLabel.home)];
      contact.organizations = _company.text.trim().isEmpty
          ? []
          : [Organization(company: _company.text.trim())];
      contact.notes = _notes.text.trim().isEmpty
          ? []
          : [Note(_notes.text.trim())];
      contact.websites = _website.text.trim().isEmpty
          ? []
          : [Website(_website.text.trim())];
      contact.events = _birthday == null
          ? []
          : [
              Event(
                year: _birthday!.year,
                month: _birthday!.month,
                day: _birthday!.day,
                label: EventLabel.birthday,
              ),
            ];

      if (_isEdit) {
        await contact.update();
      } else {
        await contact.insert();
      }

      ContactRepository().invalidateCache();
      if (!mounted) return;
      context.read<ContactBloc>().add(const LoadContacts());
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('ذخیره ناموفق بود: $e');
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _delete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف مخاطب'),
          content: const Text('این مخاطب حذف شود؟'),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text(
                'حذف',
                style: TextStyle(color: AppColors.callRejectRed),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || _editing == null) return;
    try {
      await _editing!.delete();
      ContactRepository().invalidateCache();
      if (!mounted) return;
      context.read<ContactBloc>().add(const LoadContacts());
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('حذف ناموفق بود: $e');
    }
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  // ── UI ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        appBar: AppBar(
          leading: TextButton(
            onPressed: () => Navigator.of(context).pop(),
            child: const Text('لغو'),
          ),
          leadingWidth: 72,
          title: Text(_isEdit ? 'ویرایش مخاطب' : 'مخاطب جدید'),
          actions: [
            TextButton(
              onPressed: _saving ? null : _save,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Text('ذخیره'),
            ),
          ],
        ),
        body: _loading
            ? const Center(child: CircularProgressIndicator())
            : Form(
                key: _formKey,
                child: ListView(
                  children: [
                    _buildAvatarSection(theme),
                    const SizedBox(height: 8),
                    _buildNameSection(),
                    const Divider(height: 24),
                    _buildPhoneSection(theme),
                    const Divider(height: 24),
                    _buildEmailSection(theme),
                    const Divider(height: 24),
                    ContactFormField(
                      controller: _address,
                      icon: Icons.home_outlined,
                      label: 'نشانی',
                      maxLines: 3,
                    ),
                    ContactFormField(
                      controller: _company,
                      icon: Icons.business_outlined,
                      label: 'شرکت',
                    ),
                    ContactFormField(
                      controller: _notes,
                      icon: Icons.notes_outlined,
                      label: 'یادداشت',
                      maxLines: 3,
                    ),
                    _buildMoreFields(theme),
                    if (_isEdit) _buildDeleteButton(),
                    const SizedBox(height: 32),
                  ],
                ),
              ),
      ),
    );
  }

  Widget _buildAvatarSection(ThemeData theme) {
    final name = '${_firstName.text} ${_lastName.text}'.trim();
    return Container(
      color: theme.brightness == Brightness.dark
          ? AppColors.keypadDark
          : AppColors.keypadLight,
      padding: const EdgeInsets.symmetric(vertical: 24),
      child: Center(
        child: Stack(
          children: [
            _photo != null
                ? CircleAvatar(
                    radius: 60,
                    backgroundImage: MemoryImage(_photo!),
                  )
                : AvatarWidget(
                    name: name.isEmpty ? 'مخاطب جدید' : name,
                    size: 120,
                  ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Material(
                color: theme.colorScheme.primary,
                shape: const CircleBorder(),
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: _pickPhoto,
                  child: const Padding(
                    padding: EdgeInsets.all(8),
                    child: Icon(
                      Icons.photo_camera,
                      color: Colors.white,
                      size: 20,
                    ),
                  ),
                ),
              ),
            ),
            if (_photo != null)
              Positioned(
                bottom: 0,
                left: 0,
                child: Material(
                  color: AppColors.callRejectRed,
                  shape: const CircleBorder(),
                  child: InkWell(
                    customBorder: const CircleBorder(),
                    onTap: () => setState(() => _photo = null),
                    child: const Padding(
                      padding: EdgeInsets.all(8),
                      child: Icon(
                        Icons.delete_outline,
                        color: Colors.white,
                        size: 20,
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickPhoto() async {
    try {
      final bytes = await ImagePickerService.instance.pickImage();
      if (bytes != null && mounted) setState(() => _photo = bytes);
    } catch (e) {
      _snack('انتخاب عکس ناموفق بود');
    }
  }

  Widget _buildNameSection() {
    return Column(
      children: [
        ContactFormField(
          controller: _firstName,
          icon: Icons.person_outline,
          label: 'نام',
          onChanged: (_) => setState(() {}), // refresh avatar initials
          validator: (v) {
            if ((v == null || v.trim().isEmpty) &&
                _lastName.text.trim().isEmpty) {
              return 'نام را وارد کنید';
            }
            return null;
          },
        ),
        ContactFormField(
          controller: _lastName,
          icon: null,
          label: 'نام خانوادگی',
          onChanged: (_) => setState(() {}),
        ),
      ],
    );
  }

  Widget _buildPhoneSection(ThemeData theme) {
    return Column(
      children: [
        for (var i = 0; i < _phones.length; i++) _buildPhoneRow(i, theme),
        AddMoreButton(
          label: 'افزودن شماره',
          onTap: () => setState(() => _phones.add(PhoneEntry())),
        ),
      ],
    );
  }

  Widget _buildPhoneRow(int i, ThemeData theme) {
    final entry = _phones[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Icon(
            i == 0 ? Icons.phone_outlined : null,
            color: theme.iconTheme.color?.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: entry.controller,
              keyboardType: TextInputType.phone,
              decoration: const InputDecoration(labelText: 'شماره تلفن'),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<PhoneLabel>(
            value: entry.label,
            underline: const SizedBox.shrink(),
            items: kPhoneLabels.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (v) => setState(() => entry.label = v ?? entry.label),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: _phones.length == 1
                ? null
                : () => setState(() => _phones.removeAt(i)),
          ),
        ],
      ),
    );
  }

  Widget _buildEmailSection(ThemeData theme) {
    return Column(
      children: [
        for (var i = 0; i < _emails.length; i++) _buildEmailRow(i, theme),
        AddMoreButton(
          label: 'افزودن ایمیل',
          onTap: () => setState(() => _emails.add(EmailEntry())),
        ),
      ],
    );
  }

  Widget _buildEmailRow(int i, ThemeData theme) {
    final entry = _emails[i];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          Icon(
            i == 0 ? Icons.email_outlined : null,
            color: theme.iconTheme.color?.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: TextFormField(
              controller: entry.controller,
              keyboardType: TextInputType.emailAddress,
              decoration: const InputDecoration(labelText: 'ایمیل'),
            ),
          ),
          const SizedBox(width: 8),
          DropdownButton<EmailLabel>(
            value: entry.label,
            underline: const SizedBox.shrink(),
            items: kEmailLabels.entries
                .map(
                  (e) => DropdownMenuItem(value: e.key, child: Text(e.value)),
                )
                .toList(),
            onChanged: (v) => setState(() => entry.label = v ?? entry.label),
          ),
          IconButton(
            icon: const Icon(Icons.close, size: 20),
            onPressed: () => setState(() => _emails.removeAt(i)),
          ),
        ],
      ),
    );
  }

  Widget _buildMoreFields(ThemeData theme) {
    if (!_showMore) {
      return Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: () => setState(() => _showMore = true),
          icon: const Icon(Icons.expand_more),
          label: const Text('فیلدهای بیشتر'),
        ),
      );
    }
    return Column(
      children: [
        const Divider(height: 24),
        ContactFormField(
          controller: _nickname,
          icon: Icons.badge_outlined,
          label: 'نام مستعار',
        ),
        ContactFormField(
          controller: _website,
          icon: Icons.language_outlined,
          label: 'وب‌سایت',
        ),
        ListTile(
          leading: const Icon(Icons.cake_outlined),
          title: const Text('تاریخ تولد'),
          subtitle: Text(
            _birthday == null
                ? 'تعیین نشده'
                : '${_birthday!.year}/${_birthday!.month}/${_birthday!.day}',
          ),
          trailing: _birthday == null
              ? null
              : IconButton(
                  icon: const Icon(Icons.clear),
                  onPressed: () => setState(() => _birthday = null),
                ),
          onTap: _pickBirthday,
        ),
      ],
    );
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showDatePicker(
      context: context,
      initialDate: _birthday ?? DateTime(now.year - 20),
      firstDate: DateTime(1900),
      lastDate: now,
    );
    if (picked != null) setState(() => _birthday = picked);
  }

  Widget _buildDeleteButton() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Align(
        alignment: AlignmentDirectional.centerStart,
        child: TextButton.icon(
          onPressed: _delete,
          icon: const Icon(
            Icons.delete_outline,
            color: AppColors.callRejectRed,
          ),
          label: const Text(
            'حذف مخاطب',
            style: TextStyle(color: AppColors.callRejectRed),
          ),
        ),
      ),
    );
  }
}
