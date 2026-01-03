import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_phone_direct_caller/flutter_phone_direct_caller.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';
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
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    
    return BlocBuilder<DialerBloc, DialerState>(
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

        return Container(
          color: theme.scaffoldBackgroundColor,
          child: Column(
            children: [
              // Top section: Contact suggestions and dialed number
              Expanded(
                child: _buildContactSuggestions(
                  context,
                  phoneNumber,
                  matchingContacts,
                  isNumberInContacts,
                  theme,
                  isDark,
                ),
              ),
              // Bottom section: Keypad and call button
              _buildKeypadSection(context, phoneNumber, theme, isDark),
            ],
          ),
        );
      },
    );
  }

  Widget _buildContactSuggestions(
    BuildContext context,
    String phoneNumber,
    List<ContactModel> matchingContacts,
    bool isNumberInContacts,
    ThemeData theme,
    bool isDark,
  ) {
    if (phoneNumber.isEmpty) {
      return const SizedBox.shrink();
    }

    return Container(
      color: theme.scaffoldBackgroundColor,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Section header
          Directionality(
            textDirection: TextDirection.rtl,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Text(
                'همه مخاطبین',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w400,
                  color: theme.textTheme.bodyMedium?.color,
                ),
              ),
            ),
          ),
          // Contact list
          Expanded(
            child: Directionality(
              textDirection: TextDirection.rtl,
              child: ListView.builder(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                itemCount: matchingContacts.isNotEmpty 
                    ? matchingContacts.length 
                    : (isNumberInContacts ? 0 : 1),
                itemBuilder: (context, index) {
                  if (matchingContacts.isNotEmpty) {
                    return _buildContactListItem(
                      context, 
                      matchingContacts[index],
                      theme,
                      isDark,
                    );
                  } else {
                    return _buildUnknownNumberListItem(
                      phoneNumber,
                      theme,
                      isDark,
                    );
                  }
                },
              ),
            ),
          ),
          if (matchingContacts.isEmpty && !isNumberInContacts)
            Directionality(
              textDirection: TextDirection.rtl,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                child: Text(
                  'در مخاطبین وجود ندارد',
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w400,
                    color: theme.textTheme.bodyMedium?.color,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildContactListItem(
    BuildContext context, 
    ContactModel contact,
    ThemeData theme,
    bool isDark,
  ) {
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
            // Avatar (right side for RTL)
            _buildContactAvatar(contact),
            const SizedBox(width: 12),
            // Contact info (right side for RTL)
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    contact.name,
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Directionality(
                    textDirection: TextDirection.ltr,
                    child: Text(
                      '${PersianUtils.toPersianNumber(primaryPhone)}  موبایل',
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 14,
                        color: theme.textTheme.bodyMedium?.color,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            // Call button
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: theme.colorScheme.outline,
                  width: 1,
                ),
              ),
              child: Icon(
                Icons.phone_outlined,
                size: 20,
                color: theme.textTheme.bodyMedium?.color,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildUnknownNumberListItem(
    String phoneNumber,
    ThemeData theme,
    bool isDark,
  ) {
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        children: [
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
          const SizedBox(width: 12),
          // Number info (right side for RTL)
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Directionality(
                  textDirection: TextDirection.ltr,
                  child: Text(
                    PersianUtils.toPersianNumber(phoneNumber),
                    textAlign: TextAlign.right,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w500,
                      color: theme.textTheme.bodyLarge?.color,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  _getPersianDate(DateTime.now()),
                  textAlign: TextAlign.right,
                  style: TextStyle(
                    fontSize: 14,
                    color: theme.textTheme.bodyMedium?.color,
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Call button
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(
                color: theme.colorScheme.outline,
                width: 1,
              ),
            ),
            child: Icon(
              Icons.phone_outlined,
              size: 20,
              color: theme.textTheme.bodyMedium?.color,
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

  Widget _buildKeypadSection(
    BuildContext context, 
    String phoneNumber,
    ThemeData theme,
    bool isDark,
  ) {
    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 16),
      decoration: BoxDecoration(
        color: theme.colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(28),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Number display bar when typing (or close button when empty)
          if (phoneNumber.isNotEmpty)
            _buildNumberDisplayBar(context, phoneNumber, theme, isDark)
          else
            Directionality(
              textDirection: TextDirection.rtl,
              child: Align(
                alignment: Alignment.centerRight,
                child: GestureDetector(
                  onTap: () {
                    context.read<DialerBloc>().add(const DialerNumberCleared());
                  },
                  child: Container(
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: isDark 
                          ? Colors.white.withValues(alpha: 0.1)
                          : Colors.white.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(
                      Icons.close_rounded,
                      size: 18,
                      color: theme.textTheme.bodyMedium?.color,
                    ),
                  ),
                ),
              ),
            ),
          const SizedBox(height: 12),
          _buildKeypad(context, theme, isDark),
          const SizedBox(height: 16),
          _buildCallButton(context, phoneNumber, theme, isDark),
        ],
      ),
    );
  }

  Widget _buildNumberDisplayBar(
    BuildContext context, 
    String phoneNumber,
    ThemeData theme,
    bool isDark,
  ) {
    final displayBarColor = isDark 
        ? const Color(0xFF2A2A2A)
        : const Color(0xFFD8D9DB);
    final closeButtonColor = isDark
        ? Colors.white.withValues(alpha: 0.15)
        : Colors.white.withValues(alpha: 0.6);
    
    return Directionality(
      textDirection: TextDirection.ltr,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        decoration: BoxDecoration(
          color: displayBarColor,
          borderRadius: BorderRadius.circular(14),
        ),
        child: Row(
          children: [
            // Three-dot menu
            GestureDetector(
              onTap: () {
                // Show options menu
              },
              child: Icon(
                Icons.more_vert,
                size: 20,
                color: theme.textTheme.bodyMedium?.color,
              ),
            ),
            const SizedBox(width: 6),
            // Phone number display
            Expanded(
              child: Text(
                PersianUtils.toPersianNumber(phoneNumber),
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w600,
                  color: theme.textTheme.bodyLarge?.color,
                  height: 1.0,
                ),
              ),
            ),
            const SizedBox(width: 6),
            // Close button
            GestureDetector(
              onTap: () {
                context.read<DialerBloc>().add(const DialerNumberCleared());
              },
              child: Container(
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  color: closeButtonColor,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Icon(
                  Icons.close_rounded,
                  size: 18,
                  color: theme.textTheme.bodyMedium?.color,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildKeypad(BuildContext context, ThemeData theme, bool isDark) {
    final persianNumbers = [
      ['۱', '۲', '۳'],
      ['۴', '۵', '۶'],
      ['۷', '۸', '۹'],
      ['*', '۰', '#'],
    ];

    return LayoutBuilder(
      builder: (context, constraints) {
        // Calculate button width to fit screen with proper spacing
        final availableWidth = constraints.maxWidth;
        final spacing = 10.0;
        final buttonWidth = (availableWidth - (spacing * 4)) / 3;
        
        return Column(
          children: persianNumbers.asMap().entries.map((entry) {
            final isLastRow = entry.key == persianNumbers.length - 1;
            return Padding(
              padding: EdgeInsets.only(bottom: isLastRow ? 0 : 10),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                children: entry.value.map((number) {
                  return _buildKeyButton(context, number, theme, isDark, buttonWidth);
                }).toList(),
              ),
            );
          }).toList(),
        );
      },
    );
  }

  Widget _buildKeyButton(
    BuildContext context, 
    String number,
    ThemeData theme,
    bool isDark,
    double buttonWidth,
  ) {
    final englishNumber = PersianUtils.toEnglishNumber(number);
    final isSpecial = number == '*' || number == '#';
    final buttonColor = isDark
        ? const Color(0xFF2C2C2C)
        : Colors.white;

    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: () {
          context.read<DialerBloc>().add(DialerNumberPressed(englishNumber));
        },
        borderRadius: BorderRadius.circular(20),
        child: Container(
          width: buttonWidth,
          height: 65,
          decoration: BoxDecoration(
            color: buttonColor,
            borderRadius: BorderRadius.circular(20),
            boxShadow: isDark 
                ? []
                : [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.04),
                      blurRadius: 8,
                      spreadRadius: 0,
                      offset: const Offset(0, 1),
                    ),
                  ],
          ),
          child: Center(
            child: Text(
              number,
              style: TextStyle(
                fontSize: 28,
                fontWeight: FontWeight.w600,
                color: isSpecial 
                    ? theme.textTheme.bodyMedium?.color 
                    : theme.textTheme.bodyLarge?.color,
                height: 1.0,
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildCallButton(
    BuildContext context, 
    String phoneNumber,
    ThemeData theme,
    bool isDark,
  ) {
    final isEnabled = phoneNumber.isNotEmpty;
    final callButtonColor = isEnabled 
        ? theme.colorScheme.secondary 
        : (isDark ? const Color(0xFF424242) : const Color(0xFFBDBDBD));
    
    return Center(
      child: Container(
        width: 200,
        height: 52,
        decoration: BoxDecoration(
          color: callButtonColor,
          borderRadius: BorderRadius.circular(26),
          boxShadow: isEnabled && !isDark
              ? [
                  BoxShadow(
                    color: callButtonColor.withValues(alpha: 0.3),
                    blurRadius: 10,
                    offset: const Offset(0, 3),
                  ),
                ]
              : [],
        ),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: isEnabled ? () => _makeCall(context, phoneNumber) : null,
            borderRadius: BorderRadius.circular(26),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                const Text(
                  'تماس',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                    height: 1.0,
                  ),
                ),
                const SizedBox(width: 8),
                const Icon(
                  Icons.phone,
                  color: Colors.white,
                  size: 20,
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
