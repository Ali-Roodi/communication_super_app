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

  const ContactSelectorScreen({super.key, this.pickOnly = false});

  @override
  State<ContactSelectorScreen> createState() => _ContactSelectorScreenState();
}

class _ContactSelectorScreenState extends State<ContactSelectorScreen> {
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

            // Create group button
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('ارسال گروهی به‌زودی')),
                ),
                child: Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Row(
                    children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(
                          color: theme.colorScheme.primary,
                          shape: BoxShape.circle,
                        ),
                        child: Icon(
                          Icons.group_add,
                          color: theme.colorScheme.onPrimary,
                          size: 24,
                        ),
                      ),
                      const SizedBox(width: 16),
                      Expanded(
                        child: Text(
                          'ایجاد گروه',
                          style: TextStyle(
                            fontSize: 16,
                            fontWeight: FontWeight.w500,
                            color: theme.colorScheme.onPrimaryContainer,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),

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
    final digits = _searchQuery.replaceAll(RegExp(r'[^\d+]'), '');
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
      onTap: () => _choose(phoneNumber: national),
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
        ),
      ),
    );
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

    return InkWell(
      // A message goes to one number, so a contact with several asks which.
      onTap: () async {
        final picked = await pickContactNumber(
          context,
          numbers: numbers,
          title: 'پیام به ${contact.name}',
        );
        if (picked == null || !context.mounted) return;
        _choose(phoneNumber: picked, name: contact.name);
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
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
