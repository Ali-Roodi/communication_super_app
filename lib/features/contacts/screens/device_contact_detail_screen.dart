import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_contacts/flutter_contacts.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart' as contact_events;
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_bloc.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_event.dart';
import 'package:communication_super_app/features/favorites/bloc/favorites_state.dart';
import 'package:communication_super_app/features/favorites/models/favorite_model.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/features/settings/bloc/blocked_numbers_bloc.dart';

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

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      _full = await FlutterContacts.getContact(
        widget.contact.id,
        withProperties: true,
        withPhoto: true,
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
            const SliverToBoxAdapter(child: SizedBox(height: 96)),
          ],
        ),
        floatingActionButton: FloatingActionButton.extended(
          heroTag: 'contact_detail_edit',
          onPressed: _openEditor,
          icon: const Icon(Icons.edit_outlined),
          label: const Text('ویرایش'),
        ),
      ),
    );
  }

  Future<void> _openEditor() async {
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
          content: Text('«$_name» برای همیشه از مخاطبین گوشی حذف شود؟'),
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
      final target =
          _full ?? await FlutterContacts.getContact(widget.contact.id);
      if (target == null) throw Exception('مخاطب یافت نشد');
      await target.delete();
      ContactRepository().invalidateCache();
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

  // ── Collapsing toolbar ────────────────────────────────────────────────────

  Widget _buildAppBar(BuildContext context) {
    final photo = _full?.photo ?? widget.contact.avatar;
    final norm = FavoriteModel.normalize(_primaryPhone);

    return SliverAppBar(
      expandedHeight: 280,
      pinned: true,
      actions: [
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
        // «بیشتر» — overflow actions (delete contact).
        PopupMenuButton<String>(
          icon: const Icon(Icons.more_vert),
          tooltip: 'بیشتر',
          onSelected: (value) {
            if (value == 'delete') _confirmDelete();
          },
          itemBuilder: (_) => const [
            PopupMenuItem<String>(
              value: 'delete',
              child: Row(
                children: [
                  Icon(Icons.delete_outline, color: AppColors.danger),
                  SizedBox(width: 12),
                  Text('حذف مخاطب', style: TextStyle(color: AppColors.danger)),
                ],
              ),
            ),
          ],
        ),
      ],
      flexibleSpace: FlexibleSpaceBar(
        collapseMode: CollapseMode.parallax,
        title: Text(
          _name,
          style: const TextStyle(color: Colors.white, fontSize: 18),
        ),
        background: photo != null
            ? Stack(
                fit: StackFit.expand,
                children: [
                  Image.memory(photo, fit: BoxFit.cover),
                  // Scrim so the title stays legible over the photo.
                  const DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.center,
                        end: Alignment.bottomCenter,
                        colors: [Colors.transparent, Colors.black54],
                      ),
                    ),
                  ),
                ],
              )
            : Container(
                color: PersianUtils.getAvatarColor(_name),
                alignment: Alignment.center,
                child: Text(
                  PersianUtils.getInitials(_name),
                  style: TextStyle(
                    color: Colors.white.withValues(alpha: 0.9),
                    fontSize: 72,
                    fontWeight: FontWeight.w500,
                  ),
                ),
              ),
      ),
    );
  }

  // ── Action row ──────────────────────────────────────────────────────────

  Widget _buildActionRow(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: AppDimensions.paddingMd,
        vertical: AppDimensions.paddingMd,
      ),
      child: Row(
        children: [
          Expanded(
            child: _ActionButton(
              icon: Icons.call,
              label: 'تماس',
              onTap: () => NativeCallService.instance.makeCall(_primaryPhone),
            ),
          ),
          const SizedBox(width: AppDimensions.paddingSm),
          Expanded(
            child: _ActionButton(
              icon: Icons.message_outlined,
              label: 'پیام',
              onTap: () => _openSms(_primaryPhone),
            ),
          ),
          const SizedBox(width: AppDimensions.paddingSm),
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

    // Fall back to the model's numbers if the full load failed.
    if (phones.isEmpty) {
      final fallback = widget.contact.phoneNumbers.isNotEmpty
          ? widget.contact.phoneNumbers
          : [widget.contact.primaryPhone];
      widgets.add(_sectionHeader('تلفن'));
      for (final p in fallback.where((p) => p.isNotEmpty)) {
        widgets.add(_phoneTile(p, 'موبایل'));
      }
    } else {
      widgets.add(_sectionHeader('تلفن'));
      for (final p in phones) {
        widgets.add(_phoneTile(p.number, _phoneLabelFa(p)));
      }
    }

    if (emails.isNotEmpty) {
      widgets.add(_sectionHeader('ایمیل'));
      for (final e in emails) {
        widgets.add(_emailTile(e.address, _emailLabelFa(e)));
      }
    }

    if (addresses.isNotEmpty) {
      widgets.add(_sectionHeader('نشانی'));
      for (final a in addresses) {
        widgets.add(
          ListTile(
            leading: const Icon(Icons.location_on_outlined),
            title: Text(a.address),
            trailing: IconButton(
              icon: const Icon(Icons.copy_outlined),
              tooltip: 'کپی',
              onPressed: () {
                Clipboard.setData(ClipboardData(text: a.address));
                _snack('نشانی کپی شد');
              },
            ),
          ),
        );
      }
    }

    if (notes.isNotEmpty) {
      widgets.add(_sectionHeader('یادداشت'));
      for (final n in notes) {
        widgets.add(
          ListTile(
            leading: const Icon(Icons.notes_outlined),
            title: Text(n.note),
          ),
        );
      }
    }

    return widgets;
  }

  Widget _sectionHeader(String title) {
    final theme = Theme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        // Dim-gray section titles per Figma 627:4074.
        title,
        style: TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w600,
          color: theme.textTheme.bodyMedium?.color?.withValues(alpha: 0.7),
        ),
      ),
    );
  }

  Widget _phoneTile(String number, String label) {
    return ListTile(
      leading: const Icon(Icons.phone_outlined),
      title: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.toPersianNumber(number),
          textAlign: TextAlign.right,
        ),
      ),
      subtitle: Text(label),
      trailing: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          IconButton(
            icon: const Icon(Icons.call),
            color: AppColors.callAnswerGreen,
            tooltip: 'تماس',
            onPressed: () => NativeCallService.instance.makeCall(number),
          ),
          IconButton(
            icon: const Icon(Icons.message_outlined),
            tooltip: 'پیام',
            onPressed: () => _openSms(number),
          ),
        ],
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
    final blockedBloc = context.read<BlockedNumbersBloc>();
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
                  'مسدود کردن شماره',
                  style: TextStyle(color: AppColors.callRejectRed),
                ),
                onTap: () {
                  Navigator.of(sheetCtx).pop();
                  blockedBloc.add(BlockNumber(_primaryPhone));
                  _snack('شماره مسدود شد');
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

class _ActionButton extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    // Filled light-accent rounded square (Figma 627:4074 contact actions).
    return Material(
      color: AppColors.accent.withValues(alpha: 0.12),
      borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 12),
          child: Column(
            children: [
              Icon(icon, color: theme.colorScheme.primary, size: 24),
              const SizedBox(height: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: theme.colorScheme.primary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
