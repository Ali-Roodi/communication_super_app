import 'package:equatable/equatable.dart';

/// A favorited (starred) phone number. Keyed by [normalized] (digits only) so
/// it works for device contacts and unknown numbers alike.
class FavoriteModel extends Equatable {
  final String id;
  final String phoneNumber;
  final String normalized;
  final String? name;
  final String? contactId;
  final DateTime createdAt;

  const FavoriteModel({
    required this.id,
    required this.phoneNumber,
    required this.normalized,
    this.name,
    this.contactId,
    required this.createdAt,
  });

  /// Name to show, falling back to the raw phone number.
  String get displayName =>
      (name != null && name!.isNotEmpty) ? name! : phoneNumber;

  static String normalize(String phone) =>
      phone.replaceAll(RegExp(r'[^\d]'), '');

  Map<String, dynamic> toMap() => {
    'id': id,
    'phone_number': phoneNumber,
    'normalized': normalized,
    'name': name,
    'contact_id': contactId,
    'created_at': createdAt.millisecondsSinceEpoch,
  };

  factory FavoriteModel.fromMap(Map<String, dynamic> map) => FavoriteModel(
    id: map['id'] as String,
    phoneNumber: map['phone_number'] as String,
    normalized: map['normalized'] as String,
    name: map['name'] as String?,
    contactId: map['contact_id'] as String?,
    createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
  );

  @override
  List<Object?> get props => [
    id,
    phoneNumber,
    normalized,
    name,
    contactId,
    createdAt,
  ];
}
