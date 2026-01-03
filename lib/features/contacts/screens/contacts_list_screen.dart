import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';
import 'add_edit_contact_screen.dart';
import '../models/contact_model.dart';

class ContactsListScreen extends StatefulWidget {
  const ContactsListScreen({super.key});

  @override
  State<ContactsListScreen> createState() => _ContactsListScreenState();
}

class _ContactsListScreenState extends State<ContactsListScreen> {
  final TextEditingController _searchController = TextEditingController();

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

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    
    return Scaffold(
      backgroundColor: theme.scaffoldBackgroundColor,
      body: BlocBuilder<ContactBloc, ContactState>(
        builder: (context, state) {
          if (state is ContactLoading) {
            return const Center(child: CircularProgressIndicator());
          }

          if (state is ContactError) {
            return Center(child: Text('Error: ${state.message}'));
          }

          if (state is ContactsLoaded) {
            if (state.contacts.isEmpty) {
              return const Center(
                child: Text('No contacts found'),
              );
            }

            final groupedContacts = _groupContactsAlphabetically(state.contacts);

            return Directionality(
              textDirection: TextDirection.rtl,
              child: ListView.builder(
                padding: const EdgeInsets.only(bottom: 80),
                itemCount: groupedContacts.length,
                itemBuilder: (context, index) {
                  final group = groupedContacts[index];
                  final letter = group['letter'] as String;
                  final contacts = group['contacts'] as List<ContactModel>;
                  
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      // Section header
                      Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 8,
                        ),
                        color: theme.brightness == Brightness.dark
                            ? const Color(0xFF1A1A1A)
                            : const Color(0xFFF5F5F5),
                        child: Text(
                          letter,
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                            color: theme.textTheme.bodyMedium?.color,
                          ),
                          textAlign: TextAlign.right,
                        ),
                      ),
                      // Contacts in this section
                      ...contacts.map((contact) => _buildContactItem(context, contact, theme)),
                    ],
                  );
                },
              ),
            );
          }

          return const SizedBox.shrink();
        },
      ),
      floatingActionButton: Directionality(
        textDirection: TextDirection.rtl,
        child: FloatingActionButton.extended(
          heroTag: 'contacts_fab', // Unique hero tag to avoid conflicts
          onPressed: () {
            Navigator.push(
              context,
              MaterialPageRoute(
                builder: (context) => const AddEditContactScreen(),
              ),
            );
          },
          icon: const Icon(Icons.add),
          label: const Text('افزودن مخاطب'),
          backgroundColor: const Color(0xFFC3E7FF),
          foregroundColor: theme.brightness == Brightness.dark
              ? const Color(0xFF01579B)
              : const Color(0xFF01579B),
          elevation: 6,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(24),
          ),
        ),
      ),
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
    );
  }

  List<Map<String, dynamic>> _groupContactsAlphabetically(List<ContactModel> contacts) {
    final Map<String, List<ContactModel>> grouped = {};
    
    for (var contact in contacts) {
      final firstChar = contact.name.isNotEmpty ? contact.name[0] : '#';
      grouped.putIfAbsent(firstChar, () => []).add(contact);
    }
    
    final sortedKeys = grouped.keys.toList()..sort();
    
    return sortedKeys.map((key) => {
      'letter': key,
      'contacts': grouped[key]!,
    }).toList();
  }

  Widget _buildContactItem(BuildContext context, ContactModel contact, ThemeData theme) {
    return InkWell(
      onTap: () {
        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (context) => DeviceContactDetailScreen(contact: contact),
          ),
        );
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        child: Row(
          children: [
            // Avatar on the right (RTL)
            _buildAvatar(contact),
            const SizedBox(width: 16),
            // Name
            Expanded(
              child: Text(
                contact.name,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: theme.textTheme.bodyLarge?.color,
                ),
                textAlign: TextAlign.right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

Widget _buildAvatar(ContactModel contact) {
  if (contact.avatar != null) {
    return CircleAvatar(
      radius: 24,
      backgroundImage: MemoryImage(contact.avatar!),
    );
  }
  return AvatarWidget(name: contact.name, size: 48);
}

class ContactSearchDelegate extends SearchDelegate {
  final ContactBloc contactBloc;

  ContactSearchDelegate({required this.contactBloc});

  @override
  List<Widget>? buildActions(BuildContext context) {
    return [
      IconButton(
        icon: const Icon(Icons.clear),
        onPressed: () {
          query = '';
        },
      ),
    ];
  }

  @override
  Widget? buildLeading(BuildContext context) {
    return IconButton(
      icon: const Icon(Icons.arrow_back),
      onPressed: () {
        close(context, null);
      },
    );
  }

  @override
  Widget buildResults(BuildContext context) {
    contactBloc.add(SearchContacts(query));
    return BlocBuilder<ContactBloc, ContactState>(
      bloc: contactBloc,
      builder: (context, state) {
        if (state is ContactLoading) {
          return const Center(child: CircularProgressIndicator());
        }

        if (state is ContactsLoaded) {
          if (state.contacts.isEmpty) {
            return const Center(child: Text('No contacts found'));
          }

          return ListView.builder(
            itemCount: state.contacts.length,
            itemBuilder: (context, index) {
              final contact = state.contacts[index];
              return ListTile(
                leading: AvatarWidget(name: contact.name),
                title: Text(contact.name),
                subtitle: Text(contact.primaryPhone),
                onTap: () {
                  Navigator.push(
                    context,
                    MaterialPageRoute(
                      builder: (context) => DeviceContactDetailScreen(contact: contact),
                    ),
                  );
                },
              );
            },
          );
        }

        return const SizedBox.shrink();
      },
    );
  }

  @override
  Widget buildSuggestions(BuildContext context) {
    return const SizedBox.shrink();
  }
}


