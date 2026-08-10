import 'package:flutter/material.dart';
import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/google_list.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart' as contact_events;
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/services/contact_extras_service.dart';
import 'package:communication_super_app/features/contacts/services/sim_contacts_service.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_state.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';

/// Contact detail with a collapsing toolbar, action row, and PHONE / EMAIL /
/// ADDRESS / NOTES sections. Header data comes from the [ContactModel]; full
/// details (labeled phones, emails, address, notes) are loaded by device id.
class DeviceContactDetailScreen extends StatefulWidget {
  final ContactModel contact;

  const DeviceContactDetailScreen({super.key, required this.contact});

  @override
  State<DeviceContactDetailScreen> createState() =>
      _DeviceContactDetailScreenState();
}

class _DeviceContactDetailScreenState extends State<DeviceContactDetailScreen> {
  Contact? _full;
  bool _loading = true;

  /// Ringtone / voicemail / account, read over the contact-extras channel.
  ContactExtras? _extras;

  /// Third-party rows on this contact («برنامه‌های متصل»).
  List<ConnectedApp> _connectedApps = const [];

  @override
  void initState() {
    super.initState();
    _load();
    _loadExtras();
  }

  Future<void> _loadExtras() async {
    // A SIM contact has no ContactsContract row, so there is nothing to read a
    // ringtone, a voicemail setting or a connected app from.
    if (widget.contact.isSimContact) return;
    final service = ContactExtrasService.instance;
    final extras = await service.getSettings(widget.contact.id);
    final apps = await service.getConnectedApps(widget.contact.id);
    if (!mounted) return;
    setState(() {
      _extras = extras;
      _connectedApps = apps;
    });
  }

  Future<void> _load() async {
    if (widget.contact.isSimContact) {
      // Not a ContactsContract id — the header renders from the model.
      if (mounted) setState(() => _loading = false);
      return;
    }
    try {
      _full = await FlutterContacts.getContact(
        widget.contact.id,
        withProperties: true,
        withPhoto: true,
        // Groups and accounts are opt-in; the page renders both (the account
        // shows in the footer card, like Google Contacts').
        withGroups: true,
        withAccounts: true,
      );
    } catch (_) {
      _full = null;
    }
    if (mounted) setState(() => _loading = false);
  }

  String get _name => widget.contact.name;

  String get _primaryPhone {
    if (_full != null && _full!.phones.isNotEmpty) {
      return _full!.phones.first.number;
    }
    return widget.contact.primaryPhone;
  }

  @override
  Widget build(BuildContext context) {
    return Directionality(
      textDirection: TextDirection.rtl,
      child: Scaffold(
        body: CustomScrollView(
          slivers: [
            _buildAppBar(context),
            SliverToBoxAdapter(child: _buildHeader(context)),
            SliverToBoxAdapter(child: _buildActionRow(context)),
            if (_loading)
              const SliverToBoxAdapter(
                child: Padding(
                  padding: EdgeInsets.all(32),
                  child: Center(child: CircularProgressIndicator()),
                ),
              )
            else
              SliverList(
                delegate: SliverChildListDelegate(_buildSections(context)),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 40)),
          ],
        ),
      ),
    );
  }

  /// A contact read from `content://icc/adn`. There is no editing it in place:
  /// an ADN record is one name and one number with no durable id, so the
  /// pencil becomes «کپی در تلفن» — which is what Google Contacts offers on a
  /// SIM contact too.
  bool get _isSimContact => widget.contact.isSimContact;

  Future<void> _openEditor() async {
    if (_isSimContact) {
      await Navigator.of(context).push<bool>(
        MaterialPageRoute(
          builder: (_) => AddEditContactScreen(
            initialPhone: widget.contact.primaryPhone,
            initialName: widget.contact.name,
          ),
        ),
      );
      return;
    }
    final changed = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => AddEditContactScreen(contactId: widget.contact.id),
      ),
    );
    if (changed == true && mounted) {
      setState(() => _loading = true);
      await _load();
      // If the contact was deleted while editing, leave the detail screen.
      if (mounted && _full == null) Navigator.of(context).pop();
    }
  }

  /// «حذف مخاطب» from the overflow menu: confirm, delete from the DEVICE
  /// address book, refresh the contacts list, and leave this screen.
  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف مخاطب'),
          content: Text(
            _isSimContact
                ? '«$_name» برای همیشه از سیم‌کارت حذف شود؟'
                : '«$_name» برای همیشه از مخاطبین گوشی حذف شود؟',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              style: TextButton.styleFrom(foregroundColor: AppColors.danger),
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('حذف'),
            ),
          ],
        ),
      ),
    );
    if (confirmed != true || !mounted) return;

    try {
      if (_isSimContact) {
        // The ICC provider deletes by matching the record's contents — an ADN
        // row has no id to address it by.
        final ok = await SimContactsService.delete(widget.contact);
        if (!ok) throw Exception('سیم‌کارت حذف را نپذیرفت');
      } else {
        final target =
            _full ?? await FlutterContacts.getContact(widget.contact.id);
        if (target == null) throw Exception('مخاطب یافت نشد');
        await target.delete();
      }
      ContactRepository().invalidateCache();
      LazyContactAvatar.invalidateCache();
      if (!mounted) return;
      context.read<ContactBloc>().add(const contact_events.RefreshContacts());
      Navigator.of(context).pop();
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('مخاطب حذف شد')));
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('حذف ناموفق بود: $e')));
      }
    }
  }

  // ── Toolbar (plain) + centered circular header ────────────────────────────

  Widget _buildAppBar(BuildContext context) {
    final norm = FavoriteModel.normalize(_primaryPhone);

    return SliverAppBar(
      pinned: true,
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      actions: [
        // Google Contacts keeps «ویرایش» as a pencil in the bar (no FAB).
        IconButton(
          icon: Icon(
            _isSimContact ? Icons.copy_all_outlined : Icons.edit_outlined,
          ),
          tooltip: _isSimContact ? 'کپی در تلفن' : 'ویرایش',
          onPressed: _openEditor,
        ),
        BlocBuilder<FavoritesBloc, FavoritesState>(
          builder: (context, state) {
            final isFav =
                state is FavoritesLoaded &&
                state.favorites.any((f) => f.normalized == norm);
            return IconButton(
              icon: Icon(isFav ? Icons.star : Icons.star_border),
              color: isFav ? AppColors.callHoldOrange : null,
              tooltip: isFav ? 'حذف از موردعلاقه‌ها' : 'افزودن به موردعلاقه‌ها',
              onPressed: () {
                final bloc = context.read<FavoritesBloc>();
                if (isFav) {
                  bloc.add(RemoveFavorite(norm));
                } else {
                  bloc.add(
                    AddFavorite(
                      phoneNumber: _primaryPhone,
                      name: _name,
                      contactId: widget.contact.id,
                    ),
                  );
                }
              },
            );
          },
        ),
        // No overflow menu: delete/block/share all live in the «تنظیمات مخاطب»
        // group at the bottom of the page, the way Google Contacts arranges it.
      ],
    );
  }

  /// Google Contacts' header: a large circular avatar centred over the name,
  /// with the primary number beneath it.
  Widget _buildHeader(BuildContext context) {
    final theme = Theme.of(context);
    final photo = _full?.photo ?? widget.contact.avatar;
    final brightness = theme.brightness;

    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
      child: Column(
        children: [
          // Google Contacts leads with a very large avatar (~180 dp across).
          CircleAvatar(
            radius: 90,
            backgroundColor: AvatarWidget.fillFor(_name, brightness),
            backgroundImage: photo != null ? MemoryImage(photo) : null,
            child: photo == null
                ? Text(
                    AvatarWidget.initialFor(_name),
                    style: TextStyle(
                      color: AvatarWidget.onFillFor(_name, brightness),
                      fontSize: 80,
                      fontWeight: FontWeight.w400,
                    ),
                  )
                : null,
          ),
          const SizedBox(height: 22),
          Text(
            _name,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineMedium?.copyWith(fontSize: 32),
          ),
        ],
      ),
    );
  }

  // ── Action row ──────────────────────────────────────────────────────────

  /// Every number this contact has, in address-book order.
  List<String> get _allPhones {
    final loaded = _full?.phones.map((p) => p.number).toList() ?? const [];
    if (loaded.isNotEmpty) return loaded;
    if (widget.contact.phoneNumbers.isNotEmpty) {
      return widget.contact.phoneNumbers;
    }
    return [widget.contact.primaryPhone];
  }

  /// Header call/message act on the contact as a whole, so a contact with more
  /// than one number is asked which one — the same as Google Contacts.
  Future<void> _callFromHeader() async {
    final number = await pickContactNumber(
      context,
      numbers: _allPhones,
      title: 'تماس با $_name',
    );
    if (number == null || !mounted) return;
    await placeCall(context, number);
  }

  Future<void> _messageFromHeader() async {
    final number = await pickContactNumber(
      context,
      numbers: _allPhones,
      title: 'پیام به $_name',
    );
    if (number == null || !mounted) return;
    _openSms(number);
  }

  /// Same as [_callFromHeader], but always asks which SIM.
  Future<void> _callFromHeaderPickingSim() async {
    final number = await pickContactNumber(
      context,
      numbers: _allPhones,
      title: 'تماس با $_name',
    );
    if (number == null || !mounted) return;
    await placeCallPickingSim(context, number);
  }

  /// The wide tonal capsules under the header — Google Contacts' action row.
  /// They stretch to fill the width, carry the icon inside the capsule and the
  /// label underneath, and grey out when the contact can't be reached that way.
  Widget _buildActionRow(BuildContext context) {
    final hasPhone = _primaryPhone.isNotEmpty;
    final email = _full?.emails.isNotEmpty == true
        ? _full!.emails.first.address
        : null;

    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 24, 12, 8),
      child: Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: Icons.call,
              label: 'تماس',
              onTap: hasPhone ? _callFromHeader : null,
              // Long-press = «با کدام سیم‌کارت؟». Without it a pinned default
              // voice SIM makes the other card unreachable from this page.
              onLongPress: hasPhone && SimService.isMultiSim
                  ? _callFromHeaderPickingSim
                  : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionButton(
              icon: Icons.chat_bubble,
              label: 'پیام',
              onTap: hasPhone ? _messageFromHeader : null,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionButton(
              icon: Icons.mail,
              label: 'ایمیل',
              onTap: email == null
                  ? null
                  : () {
                      Clipboard.setData(ClipboardData(text: email));
                      _snack('ایمیل کپی شد');
                    },
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _ActionButton(
              icon: Icons.more_horiz,
              label: 'بیشتر',
              onTap: _showMoreSheet,
            ),
          ),
        ],
      ),
    );
  }

  // ── Sections ──────────────────────────────────────────────────────────────

  List<Widget> _buildSections(BuildContext context) {
    final widgets = <Widget>[];
    final phones = _full?.phones ?? const <Phone>[];
    final emails = _full?.emails ?? const <Email>[];
    final addresses = _full?.addresses ?? const <Address>[];
    final notes = _full?.notes ?? const <Note>[];

    void section(String title, List<Widget> rows) {
      if (rows.isEmpty) return;
      widgets
        // Grey headings, like Google Contacts' «تنظیمات مخاطب».
        ..add(SectionLabel(title, tinted: false))
        ..add(GroupedList(children: rows));
    }

    // Fall back to the model's numbers if the full load failed.
    if (phones.isEmpty) {
      final fallback = widget.contact.phoneNumbers.isNotEmpty
          ? widget.contact.phoneNumbers
          : [widget.contact.primaryPhone];
      section('تلفن', [
        for (final p in fallback.where((p) => p.isNotEmpty))
          _phoneTile(p, 'تلفن همراه'),
      ]);
    } else {
      section('تلفن', [
        for (final p in phones) _phoneTile(p.number, _phoneLabelFa(p)),
      ]);
    }

    section('ایمیل', [
      for (final e in emails) _emailTile(e.address, _emailLabelFa(e)),
    ]);

    section('نشانی', [
      for (final a in addresses)
        _copyTile(
          icon: Icons.location_on_outlined,
          title: a.address,
          label: _addressLabelFa(a),
          copiedMessage: 'نشانی کپی شد',
        ),
    ]);

    // ── Everything the editor already stores but the page used to drop ──
    final nickname = _full?.name.nickname.trim() ?? '';
    if (nickname.isNotEmpty) {
      section('نام مستعار', [
        _copyTile(
          icon: Icons.badge_outlined,
          title: nickname,
          copiedMessage: 'نام مستعار کپی شد',
        ),
      ]);
    }

    section('محل کار', [
      for (final o in _full?.organizations ?? const <Organization>[])
        if (o.company.trim().isNotEmpty || o.title.trim().isNotEmpty)
          _copyTile(
            icon: Icons.business_outlined,
            title: [
              o.company.trim(),
              o.title.trim(),
            ].where((s) => s.isNotEmpty).join(' — '),
            copiedMessage: 'کپی شد',
          ),
    ]);

    section('تولد و مناسبت‌ها', [
      for (final e in _full?.events ?? const <Event>[])
        _copyTile(
          icon: e.label == EventLabel.birthday
              ? Icons.cake_outlined
              : Icons.event_outlined,
          title: _eventDate(e),
          label: _eventLabelFa(e),
          copiedMessage: 'تاریخ کپی شد',
        ),
    ]);

    section('وب‌سایت', [
      for (final w in _full?.websites ?? const <Website>[])
        _copyTile(
          icon: Icons.link,
          title: w.url,
          copiedMessage: 'نشانی وب کپی شد',
        ),
    ]);

    section('پیام‌رسان‌ها', [
      for (final s in _full?.socialMedias ?? const <SocialMedia>[])
        _copyTile(
          icon: Icons.alternate_email,
          title: s.userName,
          label: _socialLabelFa(s),
          copiedMessage: 'کپی شد',
        ),
    ]);

    section('یادداشت', [
      for (final n in notes)
        _copyTile(
          icon: Icons.notes_outlined,
          title: n.note,
          copiedMessage: 'یادداشت کپی شد',
        ),
    ]);

    section('گروه‌ها', [
      for (final g in _full?.groups ?? const <Group>[])
        ListTile(
          contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
          leading: const Icon(Icons.label_outline),
          title: Text(g.name),
        ),
    ]);

    // ── برنامه‌های متصل ────────────────────────────────────────────────
    // One row per action, like Google Contacts: «تماس صوتی …» / «پیام …» each
    // launch the owning app on tap.
    section('برنامه‌های متصل', [
      for (final app in _connectedApps)
        for (final action in app.actions)
          ListTile(
            contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
            leading: app.icon != null
                ? Image.memory(app.icon!, width: 28, height: 28)
                : const Icon(Icons.apps),
            title: Text(action.title),
            subtitle: Text(app.label),
            onTap: () => _openConnectedAction(action, app.packageName),
          ),
    ]);

    // ── تنظیمات مخاطب ─────────────────────────────────────────────────
    section('تنظیمات مخاطب', _contactSettingsRows());

    if (_extras?.accountLabel != null || _extras?.accountName != null) {
      widgets.add(_accountFooter());
    }

    return widgets;
  }

  /// The «تنظیمات مخاطب» group: ringtone, share, pin, voicemail routing, block
  /// and delete — the same set Google Contacts puts at the bottom of the page.
  List<Widget> _contactSettingsRows() {
    final extras = _extras;
    final scheme = Theme.of(context).colorScheme;
    return [
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
        leading: const Icon(Icons.music_note_outlined),
        title: const Text('آهنگ زنگ مخاطب'),
        subtitle: Text(extras?.ringtoneSummary ?? 'پیش‌فرض'),
        onTap: _pickRingtone,
        onLongPress: extras?.ringtoneUri == null ? null : _clearRingtone,
      ),
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
        leading: const Icon(Icons.share_outlined),
        title: const Text('هم‌رسانی مخاطب'),
        onTap: () async {
          final ok = await ContactExtrasService.instance.shareContact(
            widget.contact.id,
          );
          if (!ok && mounted) _snack('هم‌رسانی این مخاطب ممکن نشد');
        },
      ),
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
        leading: const Icon(Icons.add_to_home_screen_outlined),
        title: const Text('افزودن به صفحه اصلی'),
        onTap: () async {
          final ok = await ContactExtrasService.instance.pinToHome(
            widget.contact.id,
          );
          if (mounted) {
            _snack(ok ? 'میان‌بر به صفحه اصلی افزوده شد' : 'لانچر شما میان‌بر را پشتیبانی نمی‌کند');
          }
        },
      ),
      SwitchListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 12),
        secondary: const Icon(Icons.voicemail_outlined),
        title: const Text('ارسال مستقیم به پست صوتی'),
        value: extras?.sendToVoicemail ?? false,
        onChanged: extras == null
            ? null
            : (v) async {
                final ok = await ContactExtrasService.instance
                    .setSendToVoicemail(widget.contact.id, v);
                if (!mounted) return;
                if (ok) {
                  setState(
                    () => _extras = extras.copyWith(sendToVoicemail: v),
                  );
                } else {
                  _snack('تغییر این تنظیم ممکن نشد');
                }
              },
      ),
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
        leading: Icon(Icons.block, color: scheme.error),
        title: Text(
          'مسدود کردن و گزارش هرزنامه',
          style: TextStyle(color: scheme.error),
        ),
        onTap: () => blockNumberWithConfirm(
          context,
          phoneNumber: _primaryPhone,
          contactName: widget.contact.name,
        ),
      ),
      ListTile(
        contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 20),
        leading: Icon(Icons.delete_outline, color: scheme.error),
        title: Text('حذف', style: TextStyle(color: scheme.error)),
        onTap: _confirmDelete,
      ),
    ];
  }

  /// The card Google shows under the settings group naming the account that
  /// stores the contact.
  Widget _accountFooter() {
    final scheme = Theme.of(context).colorScheme;
    final label = _extras?.accountLabel ?? _extras?.accountName ?? '';
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 20, 12, 0),
      child: Material(
        color: scheme.surfaceContainerHigh,
        borderRadius: BorderRadius.circular(GroupRadius.outer),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
          child: Row(
            children: [
              Icon(
                Icons.smartphone_outlined,
                size: 20,
                color: scheme.onSurfaceVariant,
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Text(
                  'ذخیره‌شده در $label',
                  style: TextStyle(
                    fontSize: 14,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _openConnectedAction(
    ConnectedAppAction action,
    String packageName,
  ) async {
    final ok = await ContactExtrasService.instance.openConnectedAction(
      action.dataId,
      action.mimeType,
      packageName: packageName.isEmpty ? null : packageName,
    );
    if (!ok && mounted) _snack('برنامه‌ای برای انجام این کار پیدا نشد');
  }

  Future<void> _pickRingtone() async {
    final picked = await ContactExtrasService.instance.pickRingtone(
      widget.contact.id,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _extras = (_extras ?? const ContactExtras()).copyWith(
        ringtoneUri: picked.uri,
        ringtoneTitle: picked.title,
        clearRingtone: picked.uri == null,
      );
    });
  }

  Future<void> _clearRingtone() async {
    final ok = await ContactExtrasService.instance.clearRingtone(
      widget.contact.id,
    );
    if (!ok || !mounted) return;
    setState(
      () => _extras = (_extras ?? const ContactExtras()).copyWith(
        clearRingtone: true,
      ),
    );
    _snack('آهنگ زنگ به پیش‌فرض بازگشت');
  }

  /// The generic detail row: icon, value over its optional label, long-press or
  /// trailing tap copies the value.
  Widget _copyTile({
    required IconData icon,
    required String title,
    required String copiedMessage,
    String? label,
  }) {
    void copy() {
      Clipboard.setData(ClipboardData(text: title));
      _snack(copiedMessage);
    }

    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 8),
      leading: Icon(icon),
      title: Text(title, style: const TextStyle(fontSize: 17)),
      subtitle: label == null ? null : Text(label),
      onTap: copy,
      onLongPress: copy,
      trailing: IconButton(
        icon: const Icon(Icons.copy_outlined),
        tooltip: 'کپی',
        onPressed: copy,
      ),
    );
  }

  /// Google Contacts' phone row: a call glyph on the leading edge, the number
  /// over its label in the middle, and the message shortcut trailing. Tapping
  /// the row itself dials.
  Widget _phoneTile(String number, String label) {
    return ListTile(
      contentPadding: const EdgeInsetsDirectional.only(start: 20, end: 8),
      leading: const Icon(Icons.call_outlined),
      title: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.displayPhone(number),
          textAlign: TextAlign.right,
          style: const TextStyle(fontSize: 17),
        ),
      ),
      subtitle: Text(label),
      onTap: () => placeCall(context, number),
      onLongPress: SimService.isMultiSim
          ? () => placeCallPickingSim(context, number)
          : null,
      trailing: IconButton(
        icon: const Icon(Icons.chat_bubble_outline),
        tooltip: 'پیام',
        onPressed: () => _openSms(number),
      ),
    );
  }

  Widget _emailTile(String address, String label) {
    return ListTile(
      leading: const Icon(Icons.email_outlined),
      title: Text(address),
      subtitle: Text(label),
      trailing: IconButton(
        icon: const Icon(Icons.copy_outlined),
        tooltip: 'کپی',
        onPressed: () {
          Clipboard.setData(ClipboardData(text: address));
          _snack('ایمیل کپی شد');
        },
      ),
    );
  }

  // ── Helpers ────────────────────────────────────────────────────────────────

  void _openSms(String phone) {
    if (phone.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: PhoneNormalizer.toThreadId(phone),
          phoneNumber: phone,
          contactName: _name,
        ),
      ),
    );
  }

  void _snack(String msg) =>
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));

  void _showMoreSheet() {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheetCtx) => Directionality(
        textDirection: TextDirection.rtl,
        child: SafeArea(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              ListTile(
                leading: const Icon(Icons.copy_outlined),
                title: const Text('کپی شماره'),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  Clipboard.setData(ClipboardData(text: _primaryPhone));
                  _snack('شماره کپی شد');
                },
              ),
              ListTile(
                leading: const Icon(Icons.block, color: AppColors.callRejectRed),
                title: const Text(
                  'مسدود کردن و گزارش هرزنامه',
                  style: TextStyle(color: AppColors.callRejectRed),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  // `context`, not `sheetCtx`: the confirmation and its undo
                  // outlive the sheet being dismissed.
                  blockNumberWithConfirm(
                    context,
                    phoneNumber: _primaryPhone,
                    contactName: widget.contact.name,
                  );
                },
              ),
            ],
          ),
        ),
      ),
    );
  }

  String _phoneLabelFa(Phone p) {
    if (p.label == PhoneLabel.custom && p.customLabel.isNotEmpty) {
      return p.customLabel;
    }
    switch (p.label) {
      case PhoneLabel.mobile:
        return 'موبایل';
      case PhoneLabel.home:
        return 'منزل';
      case PhoneLabel.work:
        return 'محل کار';
      case PhoneLabel.main:
        return 'اصلی';
      default:
        return 'تلفن';
    }
  }

  String _addressLabelFa(Address a) {
    if (a.label == AddressLabel.custom && a.customLabel.isNotEmpty) {
      return a.customLabel;
    }
    switch (a.label) {
      case AddressLabel.home:
        return 'منزل';
      case AddressLabel.work:
        return 'محل کار';
      default:
        return 'نشانی';
    }
  }

  String _eventLabelFa(Event e) {
    if (e.label == EventLabel.custom && e.customLabel.isNotEmpty) {
      return e.customLabel;
    }
    switch (e.label) {
      case EventLabel.birthday:
        return 'تولد';
      case EventLabel.anniversary:
        return 'سالگرد';
      default:
        return 'مناسبت';
    }
  }

  /// Events may carry no year (a birthday saved as day+month only), so the
  /// year-less case renders «۱۵ خرداد» rather than a bogus 1900.
  String _eventDate(Event e) {
    if (e.year == null) {
      return DateFormatter.formatDayMonth(DateTime(2000, e.month, e.day));
    }
    return DateFormatter.formatDate(DateTime(e.year!, e.month, e.day));
  }

  String _socialLabelFa(SocialMedia s) {
    if (s.label == SocialMediaLabel.custom && s.customLabel.isNotEmpty) {
      return s.customLabel;
    }
    return s.label.name;
  }

  String _emailLabelFa(Email e) {
    if (e.label == EmailLabel.custom && e.customLabel.isNotEmpty) {
      return e.customLabel;
    }
    switch (e.label) {
      case EmailLabel.home:
        return 'شخصی';
      case EmailLabel.work:
        return 'محل کار';
      default:
        return 'ایمیل';
    }
  }
}

/// A wide tonal capsule with its label underneath. A null [onTap] renders the
/// disabled (grey) state Google shows when the contact has no such address.
class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  /// Long-press shortcut — «تماس» uses it to choose the SIM for one call.
  final VoidCallback? onLongPress;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final enabled = onTap != null;
    final fill = enabled
        ? scheme.secondaryContainer
        : scheme.surfaceContainerHighest;
    final fg = enabled
        ? scheme.onSecondaryContainer
        : scheme.onSurfaceVariant.withValues(alpha: 0.45);

    return Column(
      mainAxisSize: MainAxisSize.min,
      // The capsule fills the slot the parent Expanded hands it; without this
      // the Material would shrink-wrap the icon.
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: fill,
          borderRadius: BorderRadius.circular(26),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            onLongPress: onLongPress,
            child: SizedBox(
              height: 52,
              child: Icon(icon, color: fg, size: 24),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Text(
          label,
          textAlign: TextAlign.center,
          style: TextStyle(
            fontSize: 13,
            color: enabled
                ? scheme.onSurfaceVariant
                : scheme.onSurfaceVariant.withValues(alpha: 0.45),
          ),
        ),
      ],
    );
  }
}
