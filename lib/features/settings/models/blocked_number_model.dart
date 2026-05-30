import 'package:equatable/equatable.dart';

/// A blocked phone number, keyed by [normalized] (digits only).
class BlockedNumberModel extends Equatable {
  final String id;
  final String phoneNumber;
  final String normalized;
  final DateTime createdAt;

  const BlockedNumberModel({
    required this.id,
    required this.phoneNumber,
    required this.normalized,
    required this.createdAt,
  });

  static String normalize(String phone) =>
      phone.replaceAll(RegExp(r'[^\d]'), '');

  Map<String, dynamic> toMap() => {
        'id': id,
        'phone_number': phoneNumber,
        'normalized': normalized,
        'created_at': createdAt.millisecondsSinceEpoch,
      };

  factory BlockedNumberModel.fromMap(Map<String, dynamic> map) =>
      BlockedNumberModel(
        id: map['id'] as String,
        phoneNumber: map['phone_number'] as String,
        normalized: map['normalized'] as String,
        createdAt:
            DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      );

  @override
  List<Object?> get props => [id, phoneNumber, normalized, createdAt];
}
