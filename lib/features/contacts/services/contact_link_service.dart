import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// Linking and unlinking duplicate contacts, over
/// `android/.../contacts/ContactLinkHandler.kt`.
///
/// Linking is the platform's own `AggregationExceptions` operation, not a
/// rewrite: nothing is copied and nothing is deleted, each account keeps its own
/// raw contact, and [unlink] takes it apart again. See the Kotlin file for why
/// "write one contact and delete the others" is a different (and lossy) thing.
class ContactLinkService {
  ContactLinkService._();
  static final ContactLinkService instance = ContactLinkService._();

  static const MethodChannel _channel = MethodChannel(
    'com.example.communication_super_app/contact_link',
  );

  /// Links [contactIds] into one contact and returns the id the aggregate ended
  /// up under, or null when the platform refused or there was nothing to link.
  ///
  /// The returned id is **not** guaranteed to be one of the inputs — the
  /// provider re-aggregates and picks its own — so callers refresh the list
  /// rather than assuming which row survived.
  Future<String?> link(List<String> contactIds) async {
    final ids = contactIds.where((id) => id.trim().isNotEmpty).toSet().toList();
    if (ids.length < 2) return null;
    try {
      return await _channel.invokeMethod<String>('link', {'contactIds': ids});
    } on PlatformException catch (e) {
      debugPrint('Contact link failed: ${e.code} ${e.message}');
      return null;
    } on MissingPluginException {
      return null;
    }
  }

  /// Breaks a linked contact back apart. Returns how many raw contacts were
  /// separated (0 when it was not linked to begin with).
  Future<int> unlink(String contactId) async {
    try {
      return await _channel.invokeMethod<int>('unlink', {
            'contactId': contactId,
          }) ??
          0;
    } on PlatformException catch (e) {
      debugPrint('Contact unlink failed: ${e.code} ${e.message}');
      return 0;
    } on MissingPluginException {
      return 0;
    }
  }

  /// How many raw contacts sit behind this contact. More than one means it is
  /// linked — the only way to know whether to offer «جدا کردن».
  Future<int> rawContactCount(String contactId) async {
    try {
      return await _channel.invokeMethod<int>('rawContactCount', {
            'contactId': contactId,
          }) ??
          1;
    } on PlatformException {
      return 1;
    } on MissingPluginException {
      return 1;
    }
  }
}
