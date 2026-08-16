import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_bloc.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_state.dart';
import 'package:communication_super_app/features/contacts/bloc/contact_event.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/widgets/phone_number_picker.dart';
import 'package:communication_super_app/core/widgets/lazy_contact_avatar.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'broadcast_compose_screen.dart';
import 'conversation_screen.dart';

/// The recipient picker for «پیام جدید».
///
/// In the default mode picking a row *replaces* this screen with the
/// conversation. In [pickOnly] mode it instead pops with the chosen
/// [PickedRecipient], which is what «هدایت» (forward) needs so it can open the
/// target chat with the forwarded text already in the composer.
class PickedRecipient {
  final String phoneNumber;
  final String? name;
  const PickedRecipient({required this.phoneNumber, this.name});
}

class ContactSelectorScreen extends StatefulWidget {
  final bool pickOnly;

  /// Text to open the conversation with already typed — a share (`ACTION_SEND`)
  /// or an `sms:?body=…` intent that named no recipient.
  final String? initialText;

  const ContactSelectorScreen({
    super.key,
    this.pickOnly = false,
    this.initialText,
  });

  @override
  State<ContactSelectorScreen> createState() => _ContactSelectorScreenState();
}

class _ContactSelectorScreenState extends State<ContactSelectorScreen> {
  /// Recipients picked so far, keyed by canonical number so the same person
  /// cannot be added twice from two differently-formatted numbers. Empty means
  /// the screen is in its ordinary one-tap-one-recipient mode.
  final Map<String, BroadcastRecipient> _group = {};

  /// «پیام گروهی» was tapped: rows now toggle instead of opening a chat.
  bool _groupMode = false;

  /// Compiled once; the recipient filter runs it per keystroke.
  static final RegExp _nonDialable = RegExp(r'[^\d+]');

  final TextEditingController _searchController = TextEditingController();
  String _searchQuery = '';

  @override
  void initState() {
    super.initState();
    context.read<ContactBloc>().add(const LoadContacts());
  }

  @override
  void dispose() {
    _searchController.dispose();
    super.dispose();
  }

  List<ContactModel> _filterContacts(List<ContactModel> contacts) {
    // You can't text a contact with no number, so this picker — unlike the
    // contacts tab — only lists the ones that have one.
    final reachable = contacts.where((c) => c.phoneNumbers.isNotEmpty);
    if (_searchQuery.isEmpty) return reachable.toList();
    final queryLower = _searchQuery.toLowerCase();
    return reachable.where((contact) {
      final nameLower = contact.name.toLowerCase();
      final phoneLower = contact.phoneNumber.toLowerCase();
      return nameLower.contains(queryLower) || phoneLower.contains(queryLower);
    }).toList();
  }

  // Memoized filter + grouping: both walk the whole address book, and build
  // runs on every keystroke, keyboard inset and avatar that arrives.
  String? _lastFlatQuery;
  List<ContactModel>? _lastFlatSource;
  List<_ContactListRow> _flatItems = const [];

  List<_ContactListRow> _getOrBuildFlatList(List<ContactModel> contacts) {
    if (_lastFlatQuery == _searchQuery &&
        identical(_lastFlatSource, contacts)) {
      return _flatItems;
    }
    _lastFlatQuery = _searchQuery;
    _lastFlatSource = contacts;
    _flatItems = _buildFlatContactList(_filterContacts(contacts));
    return _flatItems;
  }

  List<_ContactListRow> _buildFlatContactList(List<ContactModel> contacts) {
    final Map<String, List<ContactModel>> grouped = {};
    for (var contact in contacts) {
      final firstChar = contact.name.isNotEmpty ? contact.name[0] : '#';
      grouped.putIfAbsent(firstChar, () => []).add(contact);
    }
    final sortedKeys = grouped.keys.toList()..sort();
    final flat = <_ContactListRow>[];
    for (final key in sortedKeys) {
      flat.add(_ContactListRow(letter: key));
      for (final c in grouped[key]!) {
        flat.add(_ContactListRow(contact: c));
      }
    }
    return flat;
  }

  Widget _buildSectionHeader(String letter, ThemeData theme) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      color: theme.colorScheme.surfaceContainerHighest,
      child: Text(
        letter,
        style: TextStyle(
          fontSize: 14,
          fontWeight: FontWeight.w500,
          color: theme.textTheme.bodyMedium?.color,
        ),
        textAlign: TextAlign.right,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: const RtlAppBar(title: 'انتخاب مخاطب'),
      bottomNavigationBar: _groupMode
          ? Directionality(
              textDirection: TextDirection.rtl,
              child: _buildGroupBottomBar(theme),
            )
          : null,
      body: Directionality(
        textDirection: TextDirection.rtl,
        child: Column(
          children: [
            // Search bar
            Container(
              padding: const EdgeInsets.all(16),
              child: TextField(
                controller: _searchController,
                textAlign: TextAlign.right,
                decoration: InputDecoration(
                  hintText: 'نام، شماره تلفن یا ایمیل را انتخاب کنید',
                  hintStyle: TextStyle(
                    fontSize: 14,
                    color: theme.textTheme.bodyMedium?.color?.withValues(
                      alpha: 0.6,
                    ),
                  ),
                  prefixIcon: const Icon(Icons.search),
                  filled: true,
                  fillColor: theme.colorScheme.surfaceContainerHighest,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                ),
                onChanged: (value) {
                  setState(() {
                    _searchQuery = value;
                  });
                },
              ),
            ),

            // «پیام گروهی» — turns the list into a multi-select. Hidden in
            // pickOnly mode, where the caller (forward) wants exactly one.
            if (!widget.pickOnly) _buildGroupToggle(theme),
            if (_groupMode) _buildGroupChips(theme),

            // "Send to <number>" — appears when the query looks like a phone
            // number, so an unsaved number can start a conversation directly.
            _buildSendToNumber(context, theme),

            // Contacts list
            Expanded(
              child: BlocBuilder<ContactBloc, ContactState>(
                builder: (context, state) {
                  if (state is ContactLoading) {
                    return const Center(child: CircularProgressIndicator());
                  }

                  if (state is ContactError) {
                    return Center(
                      child: Text(
                        'خطا در بارگذاری مخاطبین: ${state.message}',
                        textAlign: TextAlign.center,
                      ),
                    );
                  }

                  if (state is ContactsLoaded) {
                    final flatItems = _getOrBuildFlatList(state.contacts);

                    if (flatItems.isEmpty) {
                      return const Center(
                        child: Text(
                          'هیچ مخاطبی یافت نشد',
                          style: TextStyle(fontSize: 16),
                        ),
                      );
                    }

                    return ListView.builder(
                      itemCount: flatItems.length,
                      itemBuilder: (context, index) {
                        final item = flatItems[index];
                        if (item.isHeader) {
                          return _buildSectionHeader(item.letter!, theme);
                        }
                        return _buildContactItem(context, item.contact!, theme);
                      },
                    );
                  }

                  return const SizedBox.shrink();
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// Shows a "Send to [number]" row when the query is a dialable number.
  Widget _buildSendToNumber(BuildContext context, ThemeData theme) {
    final digits = _searchQuery.replaceAll(_nonDialable, '');
    if (digits.replaceAll('+', '').length < 4) return const SizedBox.shrink();
    final national = PhoneNormalizer.toNational(digits);
    return ListTile(
      leading: CircleAvatar(
        backgroundColor: theme.colorScheme.primary,
        child: Icon(Icons.send, color: theme.colorScheme.onPrimary, size: 20),
      ),
      title: Directionality(
        textDirection: TextDirection.ltr,
        child: Text(
          'ارسال به ${PersianUtils.toPersianNumber(national)}',
          textAlign: TextAlign.right,
        ),
      ),
      onTap: () => _groupMode
          ? _toggleGroupMember(national)
          : _choose(phoneNumber: national),
    );
  }

  /// Either hands the picked recipient back to the caller ([ContactSelectorScreen.pickOnly])
  /// or opens the conversation in place of this screen.
  void _choose({required String phoneNumber, String? name}) {
    if (widget.pickOnly) {
      Navigator.pop(
        context,
        PickedRecipient(phoneNumber: phoneNumber, name: name),
      );
      return;
    }
    // pushReplacement pops this screen off the stack so back returns straight
    // to the inbox.
    Navigator.pushReplacement(
      context,
      MaterialPageRoute(
        builder: (_) => ConversationScreen(
          threadId: PhoneNormalizer.toThreadId(phoneNumber),
          phoneNumber: phoneNumber,
          contactName: name,
          initialText: widget.initialText,
        ),
      ),
    );
  }

  // ── Group send («پیام گروهی») ────────────────────────────────────────────

  /// The entry into multi-select — a **row**, not a banner.
  ///
  /// Everything above the list is a tax on the list: this screen exists to find
  /// a person, and the first version's 80 dp filled card plus a full-width
  /// button pushed the first contact off the bottom of a phone once a chip was
  /// picked. Google Messages spends one 56 dp row on «Start group conversation»
  /// and so does this.
  Widget _buildGroupToggle(ThemeData theme) {
    final scheme = theme.colorScheme;
    if (_groupMode) {
      return Padding(
        // Directional, not LTRB: the start edge is the right one here, and a
        // physical `left: 16` put the title 8 px from the screen edge.
        padding: const EdgeInsetsDirectional.fromSTEB(16, 0, 8, 0),
        child: Row(
          children: [
            Expanded(
              child: Text(
                _group.isEmpty
                    ? 'گیرندگان پیام گروهی را انتخاب کنید'
                    : 'گیرندگان (${PersianUtils.toPersianNumber('${_group.length}')})',
                style: theme.textTheme.labelLarge?.copyWith(
                  color: scheme.primary,
                ),
                textAlign: TextAlign.right,
              ),
            ),
            TextButton(
              onPressed: () => setState(() {
                _groupMode = false;
                _group.clear();
              }),
              child: const Text('انصراف'),
            ),
          ],
        ),
      );
    }
    return ListTile(
      onTap: () => setState(() => _groupMode = true),
      contentPadding: const EdgeInsets.symmetric(horizontal: 16),
      leading: CircleAvatar(
        backgroundColor: scheme.primaryContainer,
        foregroundColor: scheme.onPrimaryContainer,
        child: const Icon(Icons.group_add_outlined),
      ),
      title: const Text(
        'پیام گروهی',
        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
      ),
    );
  }

  /// The picked recipients. Empty renders nothing at all — the header row above
  /// already says the mode is on, and an empty box that reserves height makes
  /// the list jump the moment the first chip lands.
  Widget _buildGroupChips(ThemeData theme) {
    if (_group.isEmpty) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      // Full width, or the parent Column centres the shrink-wrapped Wrap and
      // the chips float in the middle instead of starting at the right edge.
      child: SizedBox(
        width: double.infinity,
        child: Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            for (final entry in _group.entries)
              InputChip(
                label: Text(entry.value.label),
                visualDensity: VisualDensity.compact,
                onDeleted: () => setState(() => _group.remove(entry.key)),
              ),
          ],
        ),
      ),
    );
  }

  /// «نوشتن پیام (N)» — a bottom bar, so picking people never scrolls the
  /// button away and the list keeps its full height.
  Widget _buildGroupBottomBar(ThemeData theme) {
    return SafeArea(
      minimum: const EdgeInsets.fromLTRB(16, 8, 16, 12),
      child: SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _group.isEmpty ? null : _composeGroup,
          icon: const Icon(Icons.edit_outlined),
          label: Text(
            _group.isEmpty
                ? 'نوشتن پیام'
                : 'نوشتن پیام (${PersianUtils.toPersianNumber('${_group.length}')})',
          ),
        ),
      ),
    );
  }

  Future<void> _composeGroup() async {
    final sent = await Navigator.of(context).push<bool>(
      MaterialPageRoute(
        builder: (_) => BroadcastComposeScreen(
          recipients: _group.values.toList(),
          initialText: widget.initialText,
        ),
      ),
    );
    // The messages went out into their own conversations, so there is nothing
    // to come back to here.
    if (sent == true && mounted) Navigator.of(context).pop();
  }

  void _toggleGroupMember(String phoneNumber, {String? name}) {
    final recipient = BroadcastRecipient(phoneNumber: phoneNumber, name: name);
    setState(() {
      if (_group.remove(recipient.key) == null) {
        _group[recipient.key] = recipient;
      }
    });
  }

  Widget _buildContactItem(
    BuildContext context,
    ContactModel contact,
    ThemeData theme,
  ) {
    final displayPhone = PersianUtils.displayPhone(
      PhoneNormalizer.toNational(contact.phoneNumber),
    );
    final numbers = contact.phoneNumbers.isEmpty
        ? [contact.phoneNumber]
        : contact.phoneNumbers;

    final selectedKey = numbers
        .map(PhoneNormalizer.toThreadId)
        .firstWhere(_group.containsKey, orElse: () => '');

    return InkWell(
      // A message goes to one number, so a contact with several asks which —
      // in group mode too, since that is still one number per person.
      onTap: () async {
        if (_groupMode && selectedKey.isNotEmpty) {
          setState(() => _group.remove(selectedKey));
          return;
        }
        final picked = numbers.length == 1
            ? numbers.first
            : await pickContactNumber(
                context,
                numbers: numbers,
                title: 'پیام به ${contact.name}',
              );
        if (picked == null || !context.mounted) return;
        if (_groupMode) {
          _toggleGroupMember(picked, name: contact.name);
        } else {
          _choose(phoneNumber: picked, name: contact.name);
        }
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            if (_groupMode) ...[
              Icon(
                selectedKey.isNotEmpty
                    ? Icons.check_circle
                    : Icons.circle_outlined,
                size: 20,
                color: selectedKey.isNotEmpty
                    ? theme.colorScheme.primary
                    : theme.dividerColor,
              ),
              const SizedBox(width: 12),
            ],
            // Avatar on the right (RTL)
            _buildAvatar(contact),
            const SizedBox(width: 16),
            // Contact info
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                    textAlign: TextAlign.right,
                  ),
                  if (displayPhone.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      displayPhone,
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ],
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(ContactModel contact) {
    return LazyContactAvatar(
      contactId: contact.id,
      name: contact.name,
      size: 48,
    );
  }
}

class _ContactListRow {
  final String? letter;
  final ContactModel? contact;
  _ContactListRow({this.letter, this.contact});
  bool get isHeader => letter != null;
}
