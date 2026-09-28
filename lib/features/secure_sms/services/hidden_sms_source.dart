import 'package:communication_super_app/features/hidden/repositories/hidden_contacts_repository.dart';
import 'package:communication_super_app/features/hidden/services/sealed_inbox.dart';
import 'package:communication_super_app/features/hidden/services/sealing_key.dart';

/// What the encrypted-SMS engine needs from «دفترچه مخفی»: the SMS Kotlin
/// sealed from hidden contacts while the section was locked, and the names
/// the user gave them.
abstract class HiddenSmsSource {
  /// Sealed SMS, opened: `{address, body, timestamp, subscriptionId}`.
  Future<List<SealedEntry>> take();

  Future<void> remove(Iterable<int> ids);

  /// The hidden contact's name for [phone] (canonical), if it is one.
  Future<String?> nameFor(String phone);
}

class NativeHiddenSmsSource implements HiddenSmsSource {
  NativeHiddenSmsSource({
    SealedInbox? inbox,
    SealingKey? key,
    HiddenContactsRepository? contacts,
  }) : _inbox = inbox ?? SealedInbox(),
       _key = key ?? SealingKey(),
       _contacts = contacts ?? HiddenContactsRepository();

  final SealedInbox _inbox;
  final SealingKey _key;
  final HiddenContactsRepository _contacts;

  @override
  Future<List<SealedEntry>> take() async {
    // No key yet means nothing was ever sealed to one.
    final secret = await _key.secret();
    if (secret == null) return const [];
    return _inbox.open(SealedInbox.kindSms, secret);
  }

  @override
  Future<void> remove(Iterable<int> ids) => _inbox.remove(ids);

  @override
  Future<String?> nameFor(String phone) => _contacts.nameFor(phone);
}
