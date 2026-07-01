import 'package:equatable/equatable.dart';

enum CallType { incoming, outgoing, missed, rejected, blocked }

class CallLogModel extends Equatable {
  final String id;
  final String? contactId;
  final String? contactName;
  final String phoneNumber;
  final CallType callType;
  final int? duration;
  final DateTime timestamp;
  final int? simSlot;

  const CallLogModel({
    required this.id,
    this.contactId,
    this.contactName,
    required this.phoneNumber,
    required this.callType,
    this.duration,
    required this.timestamp,
    this.simSlot,
  });

  CallLogModel copyWith({String? contactId, String? contactName}) {
    return CallLogModel(
      id: id,
      contactId: contactId ?? this.contactId,
      contactName: contactName ?? this.contactName,
      phoneNumber: phoneNumber,
      callType: callType,
      duration: duration,
      timestamp: timestamp,
      simSlot: simSlot,
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
      'sim_slot': simSlot,
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
      simSlot: map['sim_slot'] as int?,
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
    simSlot,
  ];
}
