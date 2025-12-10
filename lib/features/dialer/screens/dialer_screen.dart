import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
import 'package:communication_super_app/core/widgets/lock_button.dart';
import 'package:communication_super_app/core/widgets/rtl_app_bar.dart';
import 'package:communication_super_app/core/widgets/avatar_widget.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/screens/device_contact_detail_screen.dart';

class DialerScreen extends StatelessWidget {
  const DialerScreen({super.key});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: RtlAppBar(
        title: 'شماره گیر قاسم',
        actions: const [
          IconButton(
            icon: Icon(Icons.search),
            onPressed: null,
          ),
          LockButton(),
        ],
      ),
      body: BlocBuilder<DialerBloc, DialerState>(
        builder: (context, state) {
          String phoneNumber = '';
          List<ContactModel> matchingContacts = [];
          bool isNumberInContacts = false;

          if (state is DialerInitial) {
            phoneNumber = state.phoneNumber;
            matchingContacts = state.matchingContacts;
            isNumberInContacts = state.isNumberInContacts;
          } else if (state is DialerLoading) {
            phoneNumber = state.phoneNumber;
          } else if (state is DialerFiltered) {
            phoneNumber = state.phoneNumber;
            matchingContacts = state.matchingContacts;
            isNumberInContacts = state.isNumberInContacts;
          }

          return Column(
            children: [
              // Top section: Contact suggestions and dialed number
              Expanded(
                child: _buildContactSuggestions(
                  context,
                  phoneNumber,
                  matchingContacts,
                  isNumberInContacts,
                ),
              ),
              // Bottom section: Keypad and call button
              _buildKeypadSection(context, phoneNumber),
            ],
          );
        },
      ),
    );
  }

  Widget _buildContactSuggestions(
    BuildContext context,
    String phoneNumber,
    List<ContactModel> matchingContacts,
    bool isNumberInContacts,
  ) {
    if (phoneNumber.isEmpty) {
      return const SizedBox.shrink();
    }

    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Dialed number display at top
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 8),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  icon: const Icon(Icons.more_vert),
                  onPressed: null,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                ),
                Expanded(
                  child: Text(
                    PersianUtils.toPersianNumber(phoneNumber),
                    textAlign: TextAlign.center,
                    style: Theme.of(context).textTheme.headlineMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                  ),
                ),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Backspace button (delete one digit)
                    if (phoneNumber.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.backspace, size: 20),
                        onPressed: () {
                          context.read<DialerBloc>().add(const DialerNumberDeleted());
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                    // Clear button (clear all)
                    if (phoneNumber.isNotEmpty)
                      IconButton(
                        icon: const Icon(Icons.close, size: 20),
                        onPressed: () {
                          context.read<DialerBloc>().add(const DialerNumberCleared());
                        },
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(),
                      ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 16),
          // Matching contacts section
          if (matchingContacts.isNotEmpty) ...[
            _buildSectionHeader('همه مخاطبین'),
            const SizedBox(height: 8),
            ...matchingContacts.map((contact) => _buildContactItem(context, contact)),
          ],
          // Not in contacts section
          if (phoneNumber.isNotEmpty && !isNumberInContacts) ...[
            if (matchingContacts.isNotEmpty) const SizedBox(height: 16),
            _buildSectionHeader('در مخاطبین وجود ندارد'),
            const SizedBox(height: 8),
            _buildUnknownNumberItem(phoneNumber),
          ],
        ],
      ),
    );
  }

  Widget _buildSectionHeader(String title) {
    return Text(
      title,
      style: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w600,
        color: Colors.grey,
      ),
    );
  }

  Widget _buildContactItem(BuildContext context, ContactModel contact) {
    final primaryPhone = contact.phoneNumbers.isNotEmpty
        ? contact.phoneNumbers.first
        : contact.phoneNumber;

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
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            _buildContactAvatar(contact),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      const Text(
                        'موبایل',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.grey,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        PersianUtils.toPersianNumber(primaryPhone),
                        style: const TextStyle(
                          fontSize: 14,
                          color: Colors.grey,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContactAvatar(ContactModel contact) {
    if (contact.avatar != null) {
      return CircleAvatar(
        radius: 24,
        backgroundImage: MemoryImage(contact.avatar!),
      );
    }
    return AvatarWidget(name: contact.name, size: 48);
  }

  Widget _buildUnknownNumberItem(String phoneNumber) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          const CircleAvatar(
            radius: 24,
            backgroundColor: Colors.orange,
            child: Icon(
              Icons.person,
              color: Colors.white,
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  PersianUtils.toPersianNumber(phoneNumber),
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _getPersianDate(DateTime.now()),
                  style: const TextStyle(
                    fontSize: 12,
                    color: Colors.grey,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _getPersianDate(DateTime date) {
    // Simple Persian date formatting
    // You might want to use a proper Persian date package for production
    final persianMonths = [
      'فروردین',
      'اردیبهشت',
      'خرداد',
      'تیر',
      'مرداد',
      'شهریور',
      'مهر',
      'آبان',
      'آذر',
      'دی',
      'بهمن',
      'اسفند',
    ];
    
    // Approximate conversion (for demo purposes)
    // In production, use a proper Persian calendar library
    final monthIndex = (date.month - 1) % 12;
    final day = date.day;
    final year = 1400 + (date.year - 2021); // Approximate
    
    return '$day ${persianMonths[monthIndex]} $year';
  }

  Widget _buildKeypadSection(BuildContext context, String phoneNumber) {
    return Container(
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.grey[200],
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        children: [
          const SizedBox(height: 8),
          _buildKeypad(context),
          const SizedBox(height: 16),
          _buildCallButton(context, phoneNumber),
        ],
      ),
    );
  }

  Widget _buildKeypad(BuildContext context) {
    final persianNumbers = [
      ['۱', '۲', '۳'],
      ['۴', '۵', '۶'],
      ['۷', '۸', '۹'],
      ['*', '۰', '#'],
    ];

    return Column(
      children: persianNumbers.map((row) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 8),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: row.map((number) {
              return _buildKeyButton(context, number);
            }).toList(),
          ),
        );
      }).toList(),
    );
  }

  Widget _buildKeyButton(BuildContext context, String number) {
    final englishNumber = PersianUtils.toEnglishNumber(number);
    final isSpecial = number == '*' || number == '#';

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          context.read<DialerBloc>().add(DialerNumberPressed(englishNumber));
        },
        borderRadius: BorderRadius.circular(12),
        child: Container(
          width: 80,
          height: 80,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.grey.shade300, width: 1),
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.bold,
                color: isSpecial ? Colors.grey[700] : Colors.black87,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallButton(BuildContext context, String phoneNumber) {
    return SizedBox(
      width: double.infinity,
      child: Material(
        color: phoneNumber.isNotEmpty ? Colors.green : Colors.grey[400],
        borderRadius: BorderRadius.circular(12),
        child: InkWell(
          onTap: phoneNumber.isNotEmpty
              ? () => _makeCall(context, phoneNumber)
              : null,
          borderRadius: BorderRadius.circular(12),
          child: Container(
            padding: const EdgeInsets.symmetric(vertical: 16),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'تماس',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.phone,
                  color: Colors.white,
                  size: 24,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _makeCall(BuildContext context, String phoneNumber) async {
    if (phoneNumber.isNotEmpty) {
      await FlutterPhoneDirectCaller.callNumber(phoneNumber);
    }
  }
}
