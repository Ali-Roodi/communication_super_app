import 'dart:convert';
import 'dart:typed_data';
import 'package:equatable/equatable.dart';

/// Where a contact row physically lives.
///
/// This is not decoration: a SIM contact cannot be edited in place (an ADN
/// record holds one name and one number, has a length limit set by the card,
/// and no id that survives a rewrite), so every screen that offers «ویرایش»
/// has to know which kind it is holding.
enum ContactSource {
  /// `ContactsContract` — the phone/account address book.
  phone,

  /// `content://icc/adn` on a specific SIM. Read-only in place.
  sim,
}

class ContactModel extends Equatable {
  final String id;
  final String name;
  final String phoneNumber;
  final List<String> phoneNumbers;
  final String? email;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Uint8List? avatar;

  /// Which address book this row came from.
  final ContactSource source;

  /// Subscription id of the SIM this row was read from — null for a phone
  /// contact. Kept (not the slot) because it is what the delete/insert calls
  /// address the card by; the slot is derived for display.
  final int? simSubscriptionId;

  const ContactModel({
    required this.id,
    required this.name,
    required this.phoneNumber,
    this.phoneNumbers = const [],
    this.email,
    required this.createdAt,
    required this.updatedAt,
    this.avatar,
    this.source = ContactSource.phone,
    this.simSubscriptionId,
  });

  bool get isSimContact => source == ContactSource.sim;

  String get primaryPhone =>
      phoneNumbers.isNotEmpty ? phoneNumbers.first : phoneNumber;

  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'name': name,
      'phone_number': phoneNumber,
      'email': email,
      'created_at': createdAt.millisecondsSinceEpoch,
      'updated_at': updatedAt.millisecondsSinceEpoch,
    };
  }

  factory ContactModel.fromMap(Map<String, dynamic> map) {
    return ContactModel(
      id: map['id'] as String,
      name: map['name'] as String,
      phoneNumber: map['phone_number'] as String,
      phoneNumbers: [map['phone_number'] as String],
      email: map['email'] as String?,
      createdAt: DateTime.fromMillisecondsSinceEpoch(map['created_at'] as int),
      updatedAt: DateTime.fromMillisecondsSinceEpoch(map['updated_at'] as int),
      avatar: null,
    );
  }

  /// From serialized map (e.g. from isolate) with optional avatar_base64.
  factory ContactModel.fromSerializedMap(Map<String, dynamic> map) {
    Uint8List? avatar;
    final avatarBase64 = map['avatar_base64'] as String?;
    if (avatarBase64 != null && avatarBase64.isNotEmpty) {
      try {
        avatar = Uint8List.fromList(base64Decode(avatarBase64));
      } catch (_) {}
    }
    final now = DateTime.now();
    final phones =
        (map['phone_numbers'] as List<dynamic>?)
            ?.map((e) => e as String)
            .toList() ??
        [];
    final primary = phones.isNotEmpty
        ? phones.first
        : (map['phone_number'] as String? ?? '');
    return ContactModel(
      id: map['id'] as String,
      name: map['name'] as String,
      phoneNumber: primary,
      phoneNumbers: phones,
      email: map['email'] as String?,
      createdAt: now,
      updatedAt: now,
      avatar: avatar,
    );
  }

  ContactModel copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    List<String>? phoneNumbers,
    String? email,
    DateTime? createdAt,
    DateTime? updatedAt,
    Uint8List? avatar,
    ContactSource? source,
    int? simSubscriptionId,
  }) {
    return ContactModel(
      id: id ?? this.id,
      name: name ?? this.name,
      phoneNumber: phoneNumber ?? this.phoneNumber,
      phoneNumbers: phoneNumbers ?? this.phoneNumbers,
      email: email ?? this.email,
      createdAt: createdAt ?? this.createdAt,
      updatedAt: updatedAt ?? this.updatedAt,
      avatar: avatar ?? this.avatar,
      source: source ?? this.source,
      simSubscriptionId: simSubscriptionId ?? this.simSubscriptionId,
    );
  }

  @override
  List<Object?> get props => [
    id,
    name,
    phoneNumber,
    phoneNumbers,
    email,
    createdAt,
    updatedAt,
    avatar,
    source,
    simSubscriptionId,
  ];
}
