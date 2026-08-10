import 'package:equatable/equatable.dart';

import 'package:communication_super_app/core/sim/sim_card.dart';
import 'package:communication_super_app/core/sim/sim_service.dart';

enum CallType { incoming, outgoing, missed, rejected, blocked }

class CallLogModel extends Equatable {
  final String id;
  final String? contactId;
  final String? contactName;
  final String phoneNumber;
  final CallType callType;
  final int? duration;
  final DateTime timestamp;

  /// Subscription id of the SIM this call used.
  ///
  /// This replaced a stored *slot* that was faked — `sim_slot` was written as
  /// `simDisplayName != null ? 1 : null`, i.e. every call on either card came
  /// back as «سیم ۱». The device call log records a `PHONE_ACCOUNT_ID`, which
  /// `SimService.subscriptionForAccountId` resolves to the real subscription;
  /// the slot is then *derived*, never stored, because a subscription id
  /// changes when a card is re-inserted while the slot does not.
  ///
  /// Null means unknown: a row from before this existed, a call placed over a
  /// VoIP account, or a card that has since been removed.
  final int? subscriptionId;

  const CallLogModel({
    required this.id,
    this.contactId,
    this.contactName,
    required this.phoneNumber,
    required this.callType,
    this.duration,
    required this.timestamp,
    this.subscriptionId,
  });

  /// The SIM this call used, or null when it cannot be named right now.
  SimCard? get sim => SimService.byId(subscriptionId);

  CallLogModel copyWith({String? contactId, String? contactName}) {
    return CallLogModel(
      id: id,
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      phoneNumber: phoneNumber,
      callType: callType,
      duration: duration,
      timestamp: timestamp,
      subscriptionId: subscriptionId,
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'contact_id': contactId,
      'phone_number': phoneNumber,
      'call_type': callType.name,
      'duration': duration,
      'timestamp': timestamp.millisecondsSinceEpoch,
      'subscription_id': subscriptionId,
    };
  }

  factory CallLogModel.fromMap(Map<String, dynamic> map) {
    return CallLogModel(
      id: map['id'] as String,
      contactId: map['contact_id'] as String?,
      phoneNumber: map['phone_number'] as String,
      callType: CallType.values.firstWhere(
        (e) => e.name == map['call_type'],
        orElse: () => CallType.incoming,
      ),
      duration: map['duration'] as int?,
      timestamp: DateTime.fromMillisecondsSinceEpoch(map['timestamp'] as int),
      subscriptionId: (map['subscription_id'] as num?)?.toInt(),
    );
  }

  @override
  List<Object?> get props => [
    id,
    contactId,
    contactName,
    phoneNumber,
    callType,
    duration,
    timestamp,
    subscriptionId,
  ];
}
