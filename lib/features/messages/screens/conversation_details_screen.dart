import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';

import 'package:communication_super_app/core/sim/sim_call.dart';
import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';
import 'package:communication_super_app/core/sim/widgets/sim_picker.dart';
import 'package:communication_super_app/core/theme/app_colors.dart';
import 'package:communication_super_app/core/theme/app_dimensions.dart';
import 'package:communication_super_app/core/theme/surface_roles.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/widgets/phone_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/screens/add_edit_contact_screen.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'package:communication_super_app/features/settings/screens/widgets/block_number_dialog.dart';

import '../bloc/message_bloc.dart';
import '../bloc/message_event.dart';
import '../repositories/thread_sim_repository.dart';
import 'widgets/pinch_text_scale.dart';

/// What the details page did, for the conversation behind it to act on.
enum ConversationDetailsOutcome {
  /// Nothing that closes the conversation.
  none,

  /// The number was blocked — the thread has left the inbox, so the chat
  /// sitting behind this page is showing a conversation the list no longer has.
  blocked,

  /// The user asked to delete the conversation. The delete itself belongs to
  /// the conversation (provider rows included), exactly as it does for a group.
  deleted,

  /// The conversation was archived and should not stay open over the inbox.
  archived,
}

/// What [ConversationDetailsScreen] hands back.
class ConversationDetailsResult {
  const ConversationDetailsResult({
    this.outcome = ConversationDetailsOutcome.none,
    this.sim,
  });

  final ConversationDetailsOutcome outcome;

  /// The SIM the user picked here, when they picked one. Null means "not
  /// changed" — never "no SIM".
  final SimCard? sim;
}

/// Google Messages' conversation details page: who this chat is with, which
/// card it sends on, and everything that can be done to the conversation as a
/// whole.
///
/// Reached by tapping the conversation header. That tap used to go straight to
/// the contact page, which has two problems: an unsaved number has no contact
/// page to go to, and «which SIM does this conversation send on» is a property
/// of the *conversation*, not of the person — there was nowhere to put it but
/// a chip inside the composer, which is not where Google puts it and is not
/// where anyone looked for it.
class ConversationDetailsScreen extends StatefulWidget {
  const ConversationDetailsScreen({
    super.key,
    required this.threadId,
    required this.phoneNumber,
    required this.title,
    required this.contactName,
    required this.sim,
  });

  final String threadId;
  final String phoneNumber;

  /// What the header shows — the contact's name, or the formatted number.
  final String title;

  /// Null when this number is in nobody's address book.
  final String? contactName;

  /// The card this conversation currently sends on.
  final SimCard? sim;

  @override
  State<ConversationDetailsScreen> createState() =>
      _ConversationDetailsScreenState();
}

class _ConversationDetailsScreenState extends State<ConversationDetailsScreen> {
  late SimCard? _sim = widget.sim ?? ThreadSimRepository.defaultSim;
  bool _simChanged = false;

  /// The saved contact behind this number, re-read on entry and after the
  /// editor so a rename made from here re-titles this page too.
  ContactModel? _contact;
  bool _contactResolved = false;

  String get _title => _contact?.name ?? widget.title;
  bool get _hasContact => _contact != null;

  @override
  void initState() {
    super.initState();
    _resolveContact();
    ContactRepository.revision.addListener(_resolveContact);
  }

  @override
  void dispose() {
    ContactRepository.revision.removeListener(_resolveContact);
    super.dispose();
  }

  Future<void> _resolveContact() async {
    final match = await ContactRepository().getContactByPhoneNumber(
      widget.phoneNumber,
    );
    if (!mounted) return;
    setState(() {
      _contact = match;
      _contactResolved = true;
    });
  }

  void _pop([
    ConversationDetailsOutcome outcome = ConversationDetailsOutcome.none,
  ]) {
    Navigator.of(context).pop(
      ConversationDetailsResult(
        outcome: outcome,
        sim: _simChanged ? _sim : null,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return PopScope(
      canPop: false,
      // Always answer, even on the system back gesture: a SIM picked here has
      // to reach the composer, and it is the only copy of that choice.
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _pop();
      },
      child: Directionality(
        textDirection: TextDirection.rtl,
        child: Scaffold(
          appBar: RtlAppBar(
            leading: IconButton(
              icon: const Icon(Icons.arrow_back),
              onPressed: _pop,
            ),
          ),
          body: ListView(
            padding: const EdgeInsets.only(bottom: 32),
            children: [
              _header(theme),
              const SizedBox(height: AppDimensions.paddingLg),
              // The whole SIM surface, exactly as everywhere else in the app:
              // absent on a single-SIM phone rather than greyed out.
              SimAware(
                builder: (context, _, _) =>
                    SimService.isMultiSim ? _sendingWith(theme) : _empty,
              ),
              _optionsCard(theme),
            ],
          ),
        ),
      ),
    );
  }

  static const Widget _empty = SizedBox.shrink();

  Widget _header(ThemeData theme) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Column(
        children: [
          PhoneContactAvatar(
            phoneNumber: widget.phoneNumber,
            name: _title,
            size: 96,
          ),
          const SizedBox(height: AppDimensions.paddingMd),
          Text(
            _title,
            textAlign: TextAlign.center,
            style: theme.textTheme.headlineSmall,
          ),
          // Only when the title is a name — otherwise this prints the number
          // twice.
          if (_hasContact) ...[
            const SizedBox(height: 4),
            Text(
              PersianUtils.displayPhone(
                PhoneNormalizer.toNational(widget.phoneNumber),
              ),
              style: theme.textTheme.titleMedium?.copyWith(
                color: theme.colorScheme.primary,
              ),
            ),
          ],
          const SizedBox(height: AppDimensions.paddingLg),
          _actionRow(theme),
        ],
      ),
    );
  }

  /// The tonal round buttons under the name. Deliberately short: this app has
  /// no video call and no in-conversation search, and a row of buttons that do
  /// nothing is worse than a row of two that do.
  Widget _actionRow(ThemeData theme) {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _ActionButton(
          icon: Icons.call_outlined,
          label: 'تماس',
          onTap: () => placeCall(context, widget.phoneNumber),
          // Long-press picks the card for this one call — the same gesture
          // every other call button in the app carries.
          onLongPress: SimService.isMultiSim
              ? () => placeCallPickingSim(context, widget.phoneNumber)
              : null,
        ),
        const SizedBox(width: AppDimensions.paddingLg),
        // Until the address-book lookup answers, "add" and "view" are the same
        // button with two different meanings — so it waits rather than flashing
        // «افزودن مخاطب» at somebody who is saved.
        if (_contactResolved)
          _hasContact
              ? _ActionButton(
                  icon: Icons.person_outline,
                  label: 'اطلاعات مخاطب',
                  onTap: _openContact,
                )
              : _ActionButton(
                  icon: Icons.person_add_alt_outlined,
                  label: 'افزودن مخاطب',
                  onTap: _addContact,
                ),
      ],
    );
  }

  /// «ارسال با» — the card from Google Messages' details page.
  ///
  /// It always names a concrete SIM: this conversation's remembered one, else
  /// the card pinned in Android's own settings, else slot 1. That is the whole
  /// point of the row — it is the answer to «which card does this go out on»,
  /// and «هیچ‌کدام» is not an answer.
  Widget _sendingWith(ThemeData theme) {
    final scheme = theme.colorScheme;
    final sim = _sim;
    if (sim == null) return _empty;

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
        decoration: BoxDecoration(
          color: scheme.raisedSurface,
          borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text('ارسال با', style: theme.textTheme.titleMedium),
                ),
                TextButton.icon(
                  onPressed: _pickSim,
                  icon: const Icon(Icons.swap_vert, size: 18),
                  label: const Text('تعویض'),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Row(
              children: [
                SimBadge(sim: sim),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        '${sim.slotLabel} · ${sim.name}',
                        style: theme.textTheme.bodyLarge,
                      ),
                      if (sim.subtitle case final subtitle?)
                        Directionality(
                          // A phone number is left-to-right content.
                          textDirection: TextDirection.ltr,
                          child: Text(
                            subtitle,
                            textAlign: TextAlign.right,
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _optionsCard(ThemeData theme) {
    final scheme = theme.colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Container(
        clipBehavior: Clip.antiAlias,
        decoration: BoxDecoration(
          color: scheme.raisedSurface,
          borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
        ),
        child: Column(
          children: [
            ListTile(
              leading: const Icon(Icons.format_size),
              title: const Text('اندازه متن پیام'),
              onTap: () => showMessageTextSizeSheet(context),
            ),
            ListTile(
              leading: const Icon(Icons.archive_outlined),
              title: const Text('بایگانی'),
              onTap: _archive,
            ),
            ListTile(
              leading: const Icon(Icons.block, color: AppColors.danger),
              title: const Text(
                'مسدود کردن و گزارش هرزنامه',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: _block,
            ),
            ListTile(
              leading: const Icon(
                Icons.delete_outline,
                color: AppColors.danger,
              ),
              title: const Text(
                'حذف گفتگو',
                style: TextStyle(color: AppColors.danger),
              ),
              onTap: _confirmDelete,
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _pickSim() async {
    final chosen = await showSimPicker(
      context,
      title: 'ارسال با کدام سیم‌کارت؟',
      subtitle: _title,
      selected: _sim,
    );
    if (chosen == null || !mounted) return;
    setState(() {
      _sim = chosen;
      _simChanged = true;
    });
  }

  Future<void> _openContact() async {
    final contact = _contact;
    if (contact == null) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => DeviceContactDetailScreen(contact: contact),
      ),
    );
    // The address-book revision listener re-reads for us; nothing to do here.
  }

  Future<void> _addContact() async {
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => AddEditContactScreen(initialPhone: widget.phoneNumber),
      ),
    );
  }

  void _archive() {
    context.read<MessageBloc>().add(ArchiveThreads([widget.threadId]));
    _pop(ConversationDetailsOutcome.archived);
  }

  Future<void> _block() async {
    final blocked = await blockNumberWithConfirm(
      context,
      phoneNumber: widget.phoneNumber,
      contactName: _contact?.name ?? widget.contactName,
    );
    if (blocked && mounted) _pop(ConversationDetailsOutcome.blocked);
  }

  Future<void> _confirmDelete() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => Directionality(
        textDirection: TextDirection.rtl,
        child: AlertDialog(
          title: const Text('حذف گفتگو'),
          content: const Text(
            'همه پیام‌های این گفتگو از گوشی حذف می‌شود. این کار برگشت‌پذیر نیست.',
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('انصراف'),
            ),
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text(
                'حذف',
                style: TextStyle(color: AppColors.danger),
              ),
            ),
          ],
        ),
      ),
    );
    if (confirmed == true && mounted) _pop(ConversationDetailsOutcome.deleted);
  }
}

/// One of the tonal round buttons under the name.
class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.label,
    required this.onTap,
    this.onLongPress,
  });

  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return Semantics(
      button: true,
      label: label,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Material(
            color: scheme.secondaryContainer,
            borderRadius: BorderRadius.circular(AppDimensions.radiusLg),
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: onTap,
              onLongPress: onLongPress,
              child: SizedBox(
                width: 96,
                height: 56,
                child: Icon(icon, color: scheme.onSecondaryContainer),
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(label, style: Theme.of(context).textTheme.bodySmall),
        ],
      ),
    );
  }
}
