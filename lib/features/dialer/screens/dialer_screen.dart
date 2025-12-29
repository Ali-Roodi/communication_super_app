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

    return Container(
      color: Colors.white,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Text(
              'همه مخاطبین',
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w500,
                color: Colors.grey.shade600,
              ),
            ),
          ),
          // Contact list
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              itemCount: matchingContacts.isNotEmpty 
                  ? matchingContacts.length 
                  : (isNumberInContacts ? 0 : 1),
              itemBuilder: (context, index) {
                if (matchingContacts.isNotEmpty) {
                  return _buildContactListItem(context, matchingContacts[index]);
                } else {
                  return _buildUnknownNumberListItem(phoneNumber);
                }
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildContactListItem(BuildContext context, ContactModel contact) {
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
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          children: [
            // Call button
            Container(
              width: 40,
              height: 40,
              decoration: const BoxDecoration(
                shape: BoxShape.circle,
                border: Border.fromBorderSide(
                  BorderSide(color: Color(0xFFE0E0E0), width: 1),
                ),
              ),
              child: const Icon(
                Icons.phone_outlined,
                size: 20,
                color: Color(0xFF5F6368),
              ),
            ),
            const Spacer(),
            // Contact info (right side for RTL)
            Expanded(
              flex: 4,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Text(
                    contact.name,
                    textAlign: TextAlign.right,
                    style: const TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: Color(0xFF202124),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'موبایل  ${PersianUtils.toPersianNumber(primaryPhone)}',
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 14,
                      color: Colors.grey.shade600,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 12),
            // Avatar (right side for RTL)
            _buildContactAvatar(contact),
          ],
        ),
      ),
    );
  }

  Widget _buildUnknownNumberListItem(String phoneNumber) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
          // Call button
          Container(
            width: 40,
            height: 40,
            decoration: const BoxDecoration(
              shape: BoxShape.circle,
              border: Border.fromBorderSide(
                BorderSide(color: Color(0xFFE0E0E0), width: 1),
              ),
            ),
            child: const Icon(
              Icons.phone_outlined,
              size: 20,
              color: Color(0xFF5F6368),
            ),
          ),
          const Spacer(),
          // Number info (right side for RTL)
          Expanded(
            flex: 4,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: [
                Text(
                  PersianUtils.toPersianNumber(phoneNumber),
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                    color: Color(0xFF202124),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _getPersianDate(DateTime.now()),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    color: Colors.grey.shade600,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Orange avatar for unknown number
          const CircleAvatar(
            radius: 24,
            backgroundColor: Color(0xFFFF9800),
            child: Icon(
              Icons.person,
              color: Colors.white,
              size: 24,
            ),
          ),
        ],
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
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 20),
      decoration: BoxDecoration(
        color: const Color(0xFFE8E9EB),
        borderRadius: BorderRadius.circular(32),
      ),
      child: Column(
        children: [
          // Number display bar when typing (or close button when empty)
          if (phoneNumber.isNotEmpty)
            _buildNumberDisplayBar(context, phoneNumber)
          else
            Align(
              alignment: Alignment.centerRight,
              child: GestureDetector(
                onTap: () {
                  context.read<DialerBloc>().add(const DialerNumberCleared());
                },
                child: Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.5),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: const Icon(
                    Icons.close_rounded,
                    size: 20,
                    color: Color(0xFF5F6368),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 16),
          _buildKeypad(context),
          const SizedBox(height: 24),
          _buildCallButton(context, phoneNumber),
        ],
      ),
    );
  }

  Widget _buildNumberDisplayBar(BuildContext context, String phoneNumber) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFFD8D9DB),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Row(
        children: [
          // Three-dot menu
          GestureDetector(
            onTap: () {
              // Show options menu
            },
            child: const Icon(
              Icons.more_vert,
              size: 24,
              color: Color(0xFF5F6368),
            ),
          ),
          const SizedBox(width: 8),
          // Phone number display
          Expanded(
            child: Text(
              PersianUtils.toPersianNumber(phoneNumber),
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: Color(0xFF202124),
                height: 1.0,
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Close button
          GestureDetector(
            onTap: () {
              context.read<DialerBloc>().add(const DialerNumberCleared());
            },
            child: Container(
              padding: const EdgeInsets.all(4),
              decoration: BoxDecoration(
                color: Colors.white.withOpacity(0.6),
                borderRadius: BorderRadius.circular(8),
              ),
              child: const Icon(
                Icons.close_rounded,
                size: 20,
                color: Color(0xFF5F6368),
              ),
            ),
          ),
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
      children: persianNumbers.asMap().entries.map((entry) {
        final isLastRow = entry.key == persianNumbers.length - 1;
        return Padding(
          padding: EdgeInsets.only(bottom: isLastRow ? 0 : 16),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: entry.value.map((number) {
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
        borderRadius: BorderRadius.circular(24),
        child: Container(
          width: 96,
          height: 96,
          decoration: BoxDecoration(
            color: Colors.white,
            borderRadius: BorderRadius.circular(24),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withOpacity(0.05),
                blurRadius: 10,
                spreadRadius: 0,
                offset: const Offset(0, 2),
              ),
            ],
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                fontSize: 36,
                fontWeight: FontWeight.w600,
                color: isSpecial ? const Color(0xFF5F6368) : const Color(0xFF202124),
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallButton(BuildContext context, String phoneNumber) {
    final isEnabled = phoneNumber.isNotEmpty;
    
    return Center(
      child: Container(
        width: 220,
        height: 60,
        decoration: BoxDecoration(
          color: isEnabled ? const Color(0xFF5CB85C) : const Color(0xFFBDBDBD),
          borderRadius: BorderRadius.circular(30),
          boxShadow: [
            BoxShadow(
              color: (isEnabled ? const Color(0xFF5CB85C) : const Color(0xFFBDBDBD)).withOpacity(0.3),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isEnabled ? () => _makeCall(context, phoneNumber) : null,
            borderRadius: BorderRadius.circular(30),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'تماس',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 10),
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
