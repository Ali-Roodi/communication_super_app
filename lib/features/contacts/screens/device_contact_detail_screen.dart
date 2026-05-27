import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:communication_super_app/core/widgets/lock_button.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/messages/screens/conversation_screen.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

class DeviceContactDetailScreen extends StatelessWidget {
  final ContactModel contact;

  const DeviceContactDetailScreen({super.key, required this.contact});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: const RtlAppBar(
        title: '',
        actions: [LockButton()],
      ),
      body: SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 16),
            Center(child: _buildAvatar(contact.avatar, contact.name)),
            const SizedBox(height: 12),
            Center(
              child: Text(
                contact.name,
                style: Theme.of(context).textTheme.headlineSmall,
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: [
                  _actionChip(
                    context,
                    icon: Icons.message,
                    label: 'پیام',
                    onTap: () => _startSms(context, contact.primaryPhone),
                  ),
                  _actionChip(
                    context,
                    icon: Icons.phone,
                    label: 'تماس',
                    onTap: () => _startCall(contact.primaryPhone),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 24),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: _buildPhones(context),
            ),
            if (contact.email != null && contact.email!.isNotEmpty) ...[
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: _infoRow(
                  context,
                  icon: Icons.email_outlined,
                  label: contact.email!,
                  subtitle: 'ایمیل',
                ),
              ),
            ],
            const SizedBox(height: 32),
          ],
        ),
      ),
    );
  }

  Widget _buildAvatar(Uint8List? avatar, String name) {
    if (avatar != null) {
      return CircleAvatar(
        radius: 44,
        backgroundImage: MemoryImage(avatar),
      );
    }
    return CircleAvatar(
      radius: 44,
      backgroundColor: Colors.grey.shade300,
      child: Text(
        name.isNotEmpty ? name[0] : '?',
        style: const TextStyle(fontSize: 32, color: Colors.black87),
      ),
    );
  }

  Widget _actionChip(BuildContext context,
      {required IconData icon, required String label, required VoidCallback onTap}) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(12),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
        decoration: BoxDecoration(
          color: Colors.blue.shade50,
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          children: [
            Icon(icon, color: Theme.of(context).colorScheme.primary),
            const SizedBox(height: 6),
            Text(
              label,
              style: TextStyle(color: Theme.of(context).colorScheme.primary),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPhones(BuildContext context) {
    final phones = contact.phoneNumbers.isNotEmpty
        ? contact.phoneNumbers
        : [contact.primaryPhone].where((p) => p.isNotEmpty).toList();
    return Column(
      children: phones
          .map(
            (p) => Padding(
              padding: const EdgeInsets.only(bottom: 12),
              child: _infoRow(
                context,
                icon: Icons.phone_outlined,
                label: p,
                subtitle: 'شماره',
                trailing: IconButton(
                  icon: const Icon(Icons.call),
                  onPressed: () => _startCall(p),
                ),
              ),
            ),
          )
          .toList(),
    );
  }

  Widget _infoRow(BuildContext context,
      {required IconData icon,
      required String label,
      String? subtitle,
      Widget? trailing}) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey.shade100,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, color: Colors.grey.shade700),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(label, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                if (subtitle != null)
                  Text(
                    subtitle,
                    style: const TextStyle(fontSize: 12, color: Colors.grey),
                  ),
              ],
            ),
          ),
          if (trailing != null) trailing,
        ],
      ),
    );
  }

  void _startCall(String phone) {
    if (phone.isEmpty) return;
    FlutterPhoneDirectCaller.callNumber(phone);
  }

  void _startSms(BuildContext context, String phone) {
    if (phone.isEmpty) return;
    // Normalize to canonical thread-ID (09xxxxxxxxx) so it matches stored messages
    final threadId = PhoneNormalizer.toThreadId(phone);
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => ConversationScreen(
          threadId: threadId,
          phoneNumber: phone,
          contactName: contact.name,
        ),
      ),
    );
  }
}


