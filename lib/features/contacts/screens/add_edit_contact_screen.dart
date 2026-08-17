import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/jalali_date_picker.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/services/image_picker_service.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../models/contact_form_entries.dart';
import '../repositories/contact_repository.dart';
import '../services/contact_groups_service.dart';
import '../services/sim_contacts_service.dart';
import '../widgets/group_picker_sheet.dart';
import 'widgets/contact_form_fields.dart';

/// Full-screen Add / Edit contact form. Writes to the **device** contacts
/// (flutter_contacts) so changes appear everywhere (list, favorites, dialer).
///
/// [contactId] is a device contact id (edit mode); [initialPhone] pre-fills the
/// first phone when creating, and is **appended** in edit mode — that is
/// «افزودن به مخاطب موجود», where the user picked an existing person for a
/// number that turned up in the call log or a message.
class AddEditContactScreen extends StatefulWidget {
  final String? contactId;
  final String? initialPhone;

  /// Pre-fills the name when creating. Used by «کپی در تلفن» on a SIM contact,
  /// which is a *new* phone contact seeded from a read-only ADN record.
  final String? initialName;

  const AddEditContactScreen({
    super.key,
    this.contactId,
    this.initialPhone,
    this.initialName,
  });

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

  /// Labels («برچسب‌ها») this contact carries — the ones a person applied.
  ///
  /// Written back through [ContactGroupsService.applyLabels], by name, never
  /// through `contact.groups`; see [_save]. The platform's own groups («My
  /// Contacts», «Starred in Android») are deliberately not in this list and are
  /// never written — the native side adds and removes one membership row at a
  /// time, so they simply stay where they are instead of having to be carried
  /// through every save to avoid being wiped.
  List<Group> _groups = const [];

  Contact? _editing; // populated in edit mode
  Uint8List? _photo; // selected/loaded profile photo
  bool _loading = false;
  bool _saving = false;
  bool _showMore = false;

  /// Where a *new* contact is written. Null = the phone's address book, which
  /// is the default and the only option on a phone with no SIM contacts.
  ///
  /// Google Contacts asks the same question («ذخیره در») and for the same
  /// reason: a contact on the card travels with the card. Edit mode has no
  /// picker — moving a contact between address books is a copy, not a field.
  SimCard? _saveToSim;

  bool get _isEdit => widget.contactId != null;

  /// The SIM destinations offered. Empty on a phone with no readable SIM,
  /// which is what keeps this whole row off a single-SIM-less device.
  List<SimCard> get _simTargets => _isEdit ? const [] : SimService.cached;

  @override
  void initState() {
    super.initState();
    if (_isEdit) {
      _loadContact();
    } else {
      _phones.add(PhoneEntry(text: widget.initialPhone ?? ''));
      final name = widget.initialName?.trim() ?? '';
      if (name.isNotEmpty) {
        // The card stores one undivided name; splitting on the last space is
        // the same guess the platform importer makes, and the user can fix it
        // in the two fields right in front of them.
        final cut = name.lastIndexOf(' ');
        if (cut <= 0) {
          _firstName.text = name;
        } else {
          _firstName.text = name.substring(0, cut).trim();
          _lastName.text = name.substring(cut + 1).trim();
        }
      }
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
      // Opt-in, both of them: without `withAccounts` an update throws on
      // Android (no raw id), and without `withGroups` the contact comes back
      // with an empty label list that would be written straight back over the
      // real one.
      withGroups: true,
      withAccounts: true,
    );
    if (c == null) {
      if (mounted) setState(() => _loading = false);
      return;
    }
    _editing = c;
    _photo = c.photo;
    _groups = [
      for (final g in c.groups)
        if (!ContactGroupsService.isInternal(g.name)) g,
    ];
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
    // «افزودن به مخاطب موجود»: the number the user came here with, appended
    // rather than replacing anything. Skipped when the contact already has it
    // in any equivalent form (+98912… ≡ 0912…), so picking the person the
    // number already belongs to adds a duplicate row nobody asked for.
    final incoming = widget.initialPhone?.trim() ?? '';
    if (incoming.isNotEmpty) {
      final key = PhoneNormalizer.toThreadId(incoming);
      final known = _phones.any(
        (p) => PhoneNormalizer.toThreadId(p.controller.text) == key,
      );
      if (!known) _phones.add(PhoneEntry(text: incoming));
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

      final simTarget = _saveToSim;
      if (simTarget != null) {
        await _saveToSimCard(simTarget);
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

      // Labels are written separately, NOT through `contact.groups` — see
      // [ContactGroupsService.applyLabels]. The plugin's `withGroups: true`
      // update deletes every membership row of the whole aggregate and re-adds
      // only against the first raw contact, and it writes groups that may
      // belong to an account this contact is not in, which is why a label
      // applied here used to be silently lost.
      final labelNames = ContactGroupsService.visibleNames(_groups);
      final savedId = _isEdit
          ? (await contact.update().then((c) => c.id))
          : (await contact.insert().then((c) => c.id));
      await ContactGroupsService.instance.applyLabels(savedId, labelNames);

      ContactRepository().invalidateCache();
      LazyContactAvatar.invalidateCache();
      if (!mounted) return;
      context.read<ContactBloc>().add(const LoadContacts());
      Navigator.of(context).pop(true);
    } catch (e) {
      _snack('ذخیره ناموفق بود: $e');
      if (mounted) setState(() => _saving = false);
    }
  }

  /// Writes the contact to a SIM card instead of the phone.
  ///
  /// An ADN record is **one name and one number** with a length limit set by
  /// the card, and it carries no photo, email, address or second number. Rather
  /// than silently dropping what the user typed, only the first number goes and
  /// the rest is reported — the same trade Google Contacts spells out before
  /// saving to a SIM.
  Future<void> _saveToSimCard(SimCard sim) async {
    final numbers = _phones
        .map((p) => p.controller.text.trim())
        .where((t) => t.isNotEmpty)
        .toList();
    if (numbers.isEmpty) {
      _snack('برای ذخیره روی سیم‌کارت، یک شماره لازم است');
      setState(() => _saving = false);
      return;
    }
    final name = '${_firstName.text.trim()} ${_lastName.text.trim()}'.trim();
    final ok = await SimContactsService.insert(
      subscriptionId: sim.subscriptionId,
      name: name,
      number: numbers.first,
    );
    if (!ok) {
      // A full card, or a name the record cannot hold. Never report a save
      // that did not happen — the contact would silently vanish.
      _snack('ذخیره روی ${sim.slotLabel} ممکن نشد (حافظه سیم‌کارت پر است؟)');
      if (mounted) setState(() => _saving = false);
      return;
    }
    ContactRepository().invalidateCache();
    if (!mounted) return;
    if (numbers.length > 1) {
      _snack('روی سیم‌کارت فقط نام و شماره اول ذخیره شد');
    }
    context.read<ContactBloc>().add(const RefreshContacts());
    Navigator.of(context).pop(true);
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
      LazyContactAvatar.invalidateCache();
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
                    _buildSaveTargetRow(theme),
                    _buildNameSection(),
                    const Divider(height: 24),
                    _buildPhoneSection(theme),
                    const Divider(height: 24),
                    _buildEmailSection(theme),
                    const Divider(height: 24),
                    // Labels sit in the form proper, NOT behind «فیلدهای
                    // بیشتر»: buried there nobody found them, which is the
                    // whole reason labels went unused. Google Contacts keeps
                    // them on the first screen too.
                    _buildLabelsRow(),
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

  /// «ذخیره در: تلفن» — the destination row Google Contacts puts above the
  /// name. Absent entirely when there is no SIM to offer, so a phone without
  /// one looks exactly as it did.
  Widget _buildSaveTargetRow(ThemeData theme) {
    final targets = _simTargets;
    if (targets.isEmpty) return const SizedBox.shrink();
    final selected = _saveToSim;
    return ListTile(
      dense: true,
      leading: Icon(
        selected == null ? Icons.smartphone_outlined : Icons.sim_card_outlined,
        color: theme.colorScheme.onSurfaceVariant,
        size: AppDimensions.iconLg,
      ),
      title: Text('ذخیره در', style: theme.textTheme.bodySmall),
      subtitle: Text(
        selected == null ? 'تلفن' : '${selected.slotLabel} · ${selected.name}',
        style: theme.textTheme.bodyMedium,
      ),
      trailing: const Icon(Icons.arrow_drop_down),
      onTap: () => _pickSaveTarget(targets),
    );
  }

  Future<void> _pickSaveTarget(List<SimCard> targets) async {
    final chosen = await showModalBottomSheet<Object>(
      context: context,
      builder: (sheetContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const SizedBox(height: AppDimensions.paddingSm),
              ListTile(
                leading: const Icon(Icons.smartphone_outlined),
                title: const Text('تلفن'),
                subtitle: const Text('همهٔ فیلدها، عکس و چند شماره'),
                trailing: _saveToSim == null
                    ? const Icon(Icons.check_circle)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop('phone'),
              ),
              for (final sim in targets)
                ListTile(
                  leading: const Icon(Icons.sim_card_outlined),
                  title: Text('${sim.slotLabel} · ${sim.name}'),
                  subtitle: const Text('فقط نام و یک شماره'),
                  trailing: _saveToSim?.subscriptionId == sim.subscriptionId
                      ? const Icon(Icons.check_circle)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(sim),
                ),
              const SizedBox(height: AppDimensions.paddingSm),
            ],
          ),
        ),
      ),
    );
    if (chosen == null || !mounted) return;
    setState(() => _saveToSim = chosen is SimCard ? chosen : null);
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
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ContactFieldLeading(icon: i == 0 ? Icons.phone_outlined : null),
          const SizedBox(width: 16),
          // The field itself is LTR, alone on this form: a phone number is
          // left-to-right content, and in the page's RTL direction the digits
          // were laid out right-aligned with the caret on the wrong side —
          // typing «۰۹۹۰…» read as if it were being entered backwards, and a
          // leading «+» landed at the far end of the number.
          Expanded(
            child: Directionality(
              textDirection: TextDirection.ltr,
              child: TextFormField(
                controller: entry.controller,
                keyboardType: TextInputType.phone,
                textAlign: TextAlign.left,
                decoration: const InputDecoration(
                  labelText: 'شماره تلفن',
                  // The label belongs to the Persian form, not to the LTR
                  // field it floats over.
                  alignLabelWithHint: true,
                ),
              ),
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
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          ContactFieldLeading(icon: i == 0 ? Icons.email_outlined : null),
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
        // Same rail/metrics as the text fields above (see ContactValueField).
        ContactValueField(
          icon: Icons.cake_outlined,
          label: 'تاریخ تولد',
          value: _birthday == null
              ? 'تعیین نشده'
              : DateFormatter.formatDate(_birthday!),
          onTap: _pickBirthday,
          onClear: _birthday == null
              ? null
              : () => setState(() => _birthday = null),
        ),
      ],
    );
  }

  /// «برچسب‌ها» — a *device* thing: labels sync with the account and every
  /// other contacts app on the phone sees them. The picker behind this row can
  /// also create, rename and delete, so a label never has to be made somewhere
  /// else first.
  Widget _buildLabelsRow() => ContactValueField(
    icon: Icons.label_outline,
    label: 'برچسب‌ها',
    value: _groups.isEmpty
        ? 'بدون برچسب'
        : ContactGroupsService.visibleNames(_groups).join('، '),
    onTap: _pickGroups,
    onClear: _groups.isEmpty ? null : () => setState(() => _groups = const []),
  );

  Future<void> _pickGroups() async {
    final picked = await showGroupPickerSheet(context, selected: _groups);
    if (picked == null || !mounted) return;
    setState(() => _groups = picked);
  }

  Future<void> _pickBirthday() async {
    final now = DateTime.now();
    final picked = await showAppDatePicker(
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
