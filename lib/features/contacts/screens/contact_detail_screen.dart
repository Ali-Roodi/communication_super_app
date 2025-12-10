import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import '../bloc/contact_bloc.dart';
import '../bloc/contact_event.dart';
import '../bloc/contact_state.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'add_edit_contact_screen.dart';

class ContactDetailScreen extends StatelessWidget {
  final String contactId;

  const ContactDetailScreen({
    super.key,
    required this.contactId,
  });

  @override
  Widget build(BuildContext context) {
    context.read<ContactBloc>().add(GetContactById(contactId));

    return Scaffold(
      appBar: RtlAppBar(
        actions: [
          IconButton(
            icon: const Icon(Icons.more_vert),
            onPressed: () {
              // Show menu
            },
          ),
          IconButton(
            icon: const Icon(Icons.edit),
            onPressed: () {
              Navigator.push(
                context,
                MaterialPageRoute(
                  builder: (context) => AddEditContactScreen(
                    contactId: contactId,
                  ),
                ),
              );
            },
          ),
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

          if (state is ContactLoaded) {
            final contact = state.contact;

            return SingleChildScrollView(
              child: Column(
                children: [
                  const SizedBox(height: 24),
                  AvatarWidget(name: contact.name, size: 100),
                  const SizedBox(height: 16),
                  Text(
                    contact.name,
                    style: Theme.of(context).textTheme.displayMedium,
                  ),
                  const SizedBox(height: 32),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: [
                      _buildActionButton(
                        context,
                        icon: Icons.videocam,
                        label: 'ویدئو',
                        onTap: () {
                          // Handle video call
                        },
                      ),
                      _buildActionButton(
                        context,
                        icon: Icons.phone,
                        label: 'تماس',
                        onTap: () async {
                          await FlutterPhoneDirectCaller.callNumber(
                            contact.phoneNumber,
                          );
                        },
                      ),
                      _buildActionButton(
                        context,
                        icon: Icons.message,
                        label: 'پیام',
                        onTap: () {
                          // Navigate to messages
                        },
                      ),
                    ],
                  ),
                  const SizedBox(height: 32),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            const Icon(Icons.message, size: 20),
                            const Icon(Icons.videocam, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              contact.phoneNumber,
                              style: Theme.of(context).textTheme.titleLarge,
                            ),
                            const Spacer(),
                            IconButton(
                              icon: const Icon(Icons.phone),
                              onPressed: () async {
                                await FlutterPhoneDirectCaller.callNumber(
                                  contact.phoneNumber,
                                );
                              },
                            ),
                          ],
                        ),
                        Text(
                          'موبایل',
                          style: Theme.of(context).textTheme.bodyMedium,
                        ),
                        const Divider(height: 32),
                        Text(
                          'تاریخچه',
                          style: Theme.of(context).textTheme.titleLarge,
                        ),
                        const SizedBox(height: 16),
                        _buildHistoryItem(
                          context,
                          icon: Icons.phone_missed,
                          label: 'تماس بی پاسخ',
                          date: 'امروز ۱۳:۵۹',
                        ),
                        _buildHistoryItem(
                          context,
                          icon: Icons.call_made,
                          label: 'تماس خروجی',
                          date: 'دیروز ۱۸:۳۴',
                        ),
                        _buildHistoryItem(
                          context,
                          icon: Icons.call_received,
                          label: 'تماس دریافتی',
                          date: '۱۲ خرداد ۱۵:۱۷',
                        ),
                        _buildHistoryItem(
                          context,
                          icon: Icons.message,
                          label: 'پیام دریافتی',
                          date: '۲۳ تیر ۱۴۰۳',
                        ),
                        _buildHistoryItem(
                          context,
                          icon: Icons.send,
                          label: 'پیام ارسالی',
                          date: '۲۳ تیر ۱۴۰۳',
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            );
          }

          return const SizedBox.shrink();
        },
      ),
    );
  }

  Widget _buildActionButton(
    BuildContext context, {
    required IconData icon,
    required String label,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 8),
            Text(
              label,
              style: TextStyle(
                color: Theme.of(context).colorScheme.primary,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHistoryItem(
    BuildContext context, {
    required IconData icon,
    required String label,
    required String date,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Row(
        children: [
          Icon(icon, size: 20),
          const SizedBox(width: 16),
          Text(label),
          const Spacer(),
          Text(
            date,
            style: Theme.of(context).textTheme.bodyMedium,
          ),
        ],
      ),
    );
  }
}


