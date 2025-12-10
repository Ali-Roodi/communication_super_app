import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/lock_button.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
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
    return Scaffold(
      appBar: RtlAppBar(
        title: 'مخاطبین قاسم',
        actions: [
          IconButton(
            icon: const Icon(Icons.search),
            onPressed: () {
              showSearch(
                context: context,
                delegate: ContactSearchDelegate(
                  contactBloc: context.read<ContactBloc>(),
                ),
              );
            },
          ),
          const LockButton(),
        ],
      ),
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

            return ListView.separated(
              itemCount: state.contacts.length,
              separatorBuilder: (context, index) => const Divider(height: 1),
              itemBuilder: (context, index) {
                final contact = state.contacts[index];
                return ListTile(
                  contentPadding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  leading: _buildAvatar(contact),
                  title: Text(
                    contact.name,
                    style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                  ),
                  subtitle: Text(
                    contact.primaryPhone,
                    style: const TextStyle(fontSize: 14, color: Colors.grey),
                  ),
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
      ),
      floatingActionButton: FloatingActionButton.extended(
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


