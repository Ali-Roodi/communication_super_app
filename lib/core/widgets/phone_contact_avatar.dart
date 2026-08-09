import 'package:flutter/material.dart';

import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'avatar_widget.dart';
import 'lazy_contact_avatar.dart';

/// The avatar for a **phone number**: the saved contact's photo when the number
/// belongs to one, the initials swatch otherwise.
///
/// [LazyContactAvatar] needs a device-contact id, which only the contact lists
/// have. Everything keyed by a number — the inbox rows, the conversation
/// header, the call log, «ستاره‌دار», the phone-action sheet — therefore drew
/// initials even for contacts with a photo, so the same person looked different
/// in the address book and in their own chat. This resolves the number to a
/// contact and then delegates, so there is exactly one avatar implementation.
///
/// Resolution is cheap: [ContactRepository.cachedByPhoneNumber] is an O(1) read
/// of the memoized number index, taken during `build` whenever the index is
/// already warm (the normal case — the contacts tab or the message name
/// resolution builds it early). Only a cold index costs a future, and that
/// future is the shared address-book read every other caller awaits anyway.
class PhoneContactAvatar extends StatefulWidget {
  /// Number to look up. Any format — it is normalized before matching.
  final String phoneNumber;

  /// Name (or formatted number) the initials fall back to.
  final String name;

  final double size;

  const PhoneContactAvatar({
    super.key,
    required this.phoneNumber,
    required this.name,
    this.size = 48,
  });

  @override
  State<PhoneContactAvatar> createState() => _PhoneContactAvatarState();
}

class _PhoneContactAvatarState extends State<PhoneContactAvatar> {
  /// Resolved device-contact id, or empty when the number matches no contact.
  String _contactId = '';

  @override
  void initState() {
    super.initState();
    _resolve();
  }

  @override
  void didUpdateWidget(PhoneContactAvatar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.phoneNumber != widget.phoneNumber) {
      _contactId = '';
      _resolve();
    }
  }

  void _resolve() {
    final number = widget.phoneNumber;
    if (number.isEmpty) return;

    final cached = ContactRepository.cachedByPhoneNumber(number);
    if (cached != null) {
      _contactId = cached.id;
      return;
    }
    // The index is built and holds no match: nothing to wait for.
    if (ContactRepository.hasNumberIndex) return;

    ContactRepository().getContactByPhoneNumber(number).then(
      (contact) {
        if (!mounted || contact == null || widget.phoneNumber != number) return;
        setState(() => _contactId = contact.id);
      },
      // No contacts permission, or the address-book read failed: keep the
      // initials swatch instead of raising an unhandled async error. This
      // widget also draws rows on a cold-started engine (the call UI over the
      // lock screen), where the read can legitimately fail.
      onError: (_) {},
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_contactId.isEmpty) {
      return AvatarWidget(name: widget.name, size: widget.size);
    }
    return LazyContactAvatar(
      contactId: _contactId,
      name: widget.name,
      size: widget.size,
    );
  }
}
