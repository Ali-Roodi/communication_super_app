import 'package:equatable/equatable.dart';

/// Where a contact gets written: the phone, a SIM card, or a cloud account the
/// phone syncs on its own.
class ContactSaveTarget extends Equatable {
  const ContactSaveTarget.phone()
    : subscriptionId = null,
      accountType = null,
      accountName = null;

  const ContactSaveTarget.sim(int this.subscriptionId)
    : accountType = null,
      accountName = null;

  const ContactSaveTarget.account(
    String this.accountType,
    String this.accountName,
  ) : subscriptionId = null;

  final int? subscriptionId;
  final String? accountType;
  final String? accountName;

  bool get isPhone => !isSim && !isAccount;
  bool get isSim => subscriptionId != null;
  bool get isAccount => accountType != null;

  String encode() {
    if (isSim) return 'sim:$subscriptionId';
    if (isAccount) return 'account:$accountType|$accountName';
    return 'phone';
  }

  /// Null for anything this build did not write.
  static ContactSaveTarget? decode(String? stored) {
    if (stored == null) return null;
    if (stored == 'phone') return const ContactSaveTarget.phone();
    if (stored.startsWith('sim:')) {
      final id = int.tryParse(stored.substring(4));
      return id == null ? null : ContactSaveTarget.sim(id);
    }
    if (stored.startsWith('account:')) {
      final body = stored.substring(8);
      final bar = body.indexOf('|');
      if (bar <= 0 || bar == body.length - 1) return null;
      return ContactSaveTarget.account(
        body.substring(0, bar),
        body.substring(bar + 1),
      );
    }
    return null;
  }

  @override
  List<Object?> get props => [subscriptionId, accountType, accountName];
}
