import 'package:flutter/material.dart';

import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/contacts/widgets/save_number_actions.dart';

import '../models/message_group.dart';
import '../repositories/group_repository.dart';
import 'contact_selector_screen.dart';
import 'conversation_screen.dart';

/// What a group conversation *is*, and the only place it can be changed: its
/// name, who is in it, and the way out.
///
/// Reached from the header of the conversation (tapping the title, the way
/// Google Messages opens «Group details») and from its overflow menu.
///
/// Pops with the updated [MessageGroup], or with `null` when the group was
/// deleted — the conversation behind it has to know which, since a deleted group
/// has no thread left to sit on.
class GroupDetailsScreen extends StatefulWidget {
  const GroupDetailsScreen({super.key, required this.group});

  final MessageGroup group;

  @override
  State<GroupDetailsScreen> createState() => _GroupDetailsScreenState();
}

/// What [GroupDetailsScreen] hands back.
class GroupDetailsResult {
  const GroupDetailsResult({required this.group, this.deleted = false});
  final MessageGroup group;
  final bool deleted;
}

class _GroupDetailsScreenState extends State<GroupDetailsScreen> {
  final GroupRepository _repository = GroupRepository();
  late MessageGroup _group = widget.group;

  Future<void> _reload() async {
    final fresh = await _repository.getById(_group.id);
    if (!mounted || fresh == null) return;
    setState(() => _group = fresh);
  }

  void _pop({bool deleted = false}) => Navigator.of(
    context,
  ).pop(GroupDetailsResult(group: _group, deleted: deleted));

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;

    return PopScope(
      canPop: false,
      onPopInvokedWithResult: (didPop, _) {
        // Always answer with the current group: the conversation's header is
        // rebuilt from it, so a rename made here has to travel back even when
        // the user leaves with the system back gesture.
        if (!didPop) _pop();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: const RtlAppBar(title: 'جزئیات گروه'),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _buildHeader(theme),
              const SizedBox(height: 8),
              _buildAddRow(theme),
              for (final member in _group.members) _buildMemberRow(member),
              const SizedBox(height: 16),
              Divider(height: 1, color: scheme.outlineVariant),
              ListTile(
                leading: Icon(Icons.delete_outline, color: AppColors.danger),
                title: const Text(
                  'حذف گروه و گفتگو',
                  style: TextStyle(color: AppColors.danger),
                ),
                onTap: _confirmDelete,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildHeader(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
      child: Column(
        children: [
          Container(
            width: 88,
            height: 88,
            decoration: BoxDecoration(
              color: scheme.secondaryContainer,
              shape: BoxShape.circle,
            ),
            alignment: Alignment.center,
            child: Icon(
              Icons.group_outlined,
              size: 40,
              color: scheme.onSecondaryContainer,
            ),
          ),
          const SizedBox(height: 12),
          Text(
            _group.displayTitle,
            textAlign: TextAlign.center,
            style: theme.textTheme.titleLarge,
          ),
          const SizedBox(height: 4),
          Text(_group.memberCountLabel, style: theme.textTheme.bodyMedium),
          const SizedBox(height: 12),
          OutlinedButton.icon(
            onPressed: _rename,
            icon: const Icon(Icons.edit_outlined, size: 18),
            label: Text(_group.hasTitle ? 'تغییر نام گروه' : 'نام‌گذاری گروه'),
          ),
          const SizedBox(height: 8),
          // Said once, where the group is explained rather than on every screen:
          // without MMS a group send is N separate messages, and that is what
          // decides where the answers turn up.
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: scheme.raisedSurface,
              borderRadius: BorderRadius.circular(16),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.info_outline,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'پیام‌های این گروه به‌صورت پیامک جداگانه برای هر عضو ارسال '
                    'می‌شود و پاسخ هر نفر در گفتگوی خودش می‌آید.',
                    style: theme.textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAddRow(ThemeData theme) {
    final scheme = theme.colorScheme;
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: const Icon(Icons.person_add_alt),
      ),
      title: const Text('افزودن اعضا'),
      onTap: _addMembers,
    );
  }

  Widget _buildMemberRow(GroupMember member) {
    return ListTile(
      leading: PhoneContactAvatar(
        phoneNumber: member.phoneNumber,
        name: member.label,
        size: 44,
      ),
      title: Text(member.label, maxLines: 1, overflow: TextOverflow.ellipsis),
      subtitle: Directionality(
        // A phone number is left-to-right content; in the page's RTL direction a
        // leading «+» would land at the far end.
        textDirection: TextDirection.ltr,
        child: Text(
          PersianUtils.displayPhone(
            PhoneNormalizer.toNational(member.phoneNumber),
          ),
          textAlign: TextAlign.right,
        ),
      ),
      // Tapping a member opens the 1:1 conversation — which is exactly where
      // that person's replies to the group land, so it is the useful move.
      onTap: () => Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => ConversationScreen.forPhone(
            member.phoneNumber,
            contactName: member.displayName,
          ),
        ),
      ),
      trailing: PopupMenuButton<String>(
        position: PopupMenuPosition.under,
        onSelected: (value) => _onMemberMenu(value, member),
        itemBuilder: (_) => [
          const PopupMenuItem(value: 'chat', child: Text('گفتگوی جداگانه')),
          // The two ways to keep a number, exactly as «اخیر» and the tapped-number
          // sheet offer them — a second number for somebody already saved is the
          // more common case, and it has to be reachable from here too.
          if (member.displayName == null) ...[
            const PopupMenuItem(value: 'save', child: Text('ایجاد مخاطب جدید')),
            const PopupMenuItem(
              value: 'saveExisting',
              child: Text('افزودن به مخاطب موجود'),
            ),
          ] else
            const PopupMenuItem(value: 'contact', child: Text('مشاهده مخاطب')),
          const PopupMenuItem(
            value: 'remove',
            child: Text('حذف از گروه', style: TextStyle(color: AppColors.danger)),
          ),
        ],
      ),
    );
  }

  Future<void> _onMemberMenu(String value, GroupMember member) async {
    switch (value) {
      case 'chat':
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => ConversationScreen.forPhone(
              member.phoneNumber,
              contactName: member.displayName,
            ),
          ),
        );
      case 'save':
        await createContactWithNumber(context, member.phoneNumber);
        if (mounted) await _refreshNames();
      case 'saveExisting':
        await addNumberToExistingContact(context, member.phoneNumber);
        if (mounted) await _refreshNames();
      case 'contact':
        final match = await ContactRepository().getContactByPhoneNumber(
          member.phoneNumber,
        );
        if (!mounted) return;
        if (match == null) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('این شماره در مخاطبین نیست')),
          );
          return;
        }
        await Navigator.of(context).push(
          MaterialPageRoute(
            builder: (_) => DeviceContactDetailScreen(contact: match),
          ),
        );
      case 'remove':
        await _confirmRemove(member);
    }
  }

  /// Re-reads the members' names from the address book after one was saved, so
  /// the row stops showing a bare number without leaving the page.
  Future<void> _refreshNames() async {
    final repository = ContactRepository();
    final updated = <GroupMember>[];
    var changed = false;
    for (final member in _group.members) {
      if (member.displayName != null) {
        updated.add(member);
        continue;
      }
      final match = await repository.getContactByPhoneNumber(
        member.phoneNumber,
      );
      if (match == null) {
        updated.add(member);
        continue;
      }
      changed = true;
      updated.add(member.copyWith(displayName: match.name));
    }
    if (!changed || !mounted) return;
    await _repository.addMembers(_group.id, updated);
    await _reload();
  }

  Future<void> _rename() async {
    final controller = TextEditingController(text: _group.title ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('نام گروه'),
          content: TextField(
            controller: controller,
            autofocus: true,
            textInputAction: TextInputAction.done,
            decoration: const InputDecoration(
              hintText: 'مثلاً: همکاران دفتر',
            ),
            onSubmitted: (value) => Navigator.pop(ctx, value),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('انصراف'),
            ),
            TextButton(
              // An empty name is a real answer: it clears the title and the
              // derived «علی، مریم و ۲ نفر دیگر» comes back.
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('ذخیره'),
            ),
          ],
        ),
      ),
    );
    controller.dispose();
    if (name == null || !mounted) return;
    await _repository.rename(_group.id, name);
    await _reload();
  }

  Future<void> _addMembers() async {
    final picked = await Navigator.of(context).push<List<GroupMember>>(
      MaterialPageRoute(
        builder: (_) => ContactSelectorScreen(
          pickMembers: true,
          excludeNormalized: _group.memberKeys,
        ),
      ),
    );
    if (picked == null || picked.isEmpty || !mounted) return;
    await _repository.addMembers(_group.id, picked);
    await _reload();
  }

  Future<void> _confirmRemove(GroupMember member) async {
    // A group of one is not a group: removing the last-but-one member would
    // leave a thread that can only ever hold a copy of a 1:1 conversation, so the
    // way out at that point is deleting the group.
    if (_group.members.length <= 2) {
      final ok = await _confirm(
        'با حذف این عضو، گروه کمتر از دو نفر می‌شود. کل گروه حذف شود؟',
        confirmLabel: 'حذف گروه',
      );
      if (ok) await _deleteGroup();
      return;
    }
    final ok = await _confirm(
      '«${member.label}» از این گروه حذف شود؟ پیام‌های بعدی برای او ارسال '
      'نمی‌شود.',
      confirmLabel: 'حذف',
    );
    if (!ok) return;
    await _repository.removeMember(_group.id, member.normalized);
    await _reload();
  }

  Future<void> _confirmDelete() async {
    final ok = await _confirm(
      'این گروه و همه پیام‌های آن حذف شود؟ این عمل قابل بازگشت نیست.',
      confirmLabel: 'حذف',
    );
    if (ok) await _deleteGroup();
  }

  /// The delete itself is the conversation's job — it goes through
  /// `SmsService.deleteThreadGlobally`, which also removes the provider rows the
  /// group's messages produced. This page only says so and gets out of the way.
  Future<void> _deleteGroup() async {
    if (!mounted) return;
    _pop(deleted: true);
  }

  Future<bool> _confirm(String message, {required String confirmLabel}) async {
    final result = await showDialog<bool>(
      context: context,
      builder: (ctx) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          content: Text(message),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('لغو'),
            ),
            TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: Text(
                confirmLabel,
                style: const TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    return result ?? false;
  }
}
