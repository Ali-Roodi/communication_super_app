import 'dart:typed_data';
import 'package:equatable/equatable.dart';

class ContactModel extends Equatable {
  final String id;
  final String name;
  final String phoneNumber;
  final List<String> phoneNumbers;
  final String? email;
  final DateTime createdAt;
  final DateTime updatedAt;
  final Uint8List? avatar;

  const ContactModel({
    required this.id,
    required this.name,
    required this.phoneNumber,
    this.phoneNumbers = const [],
    this.email,
    required this.createdAt,
    required this.updatedAt,
    this.avatar,
  });

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

  ContactModel copyWith({
    String? id,
    String? name,
    String? phoneNumber,
    List<String>? phoneNumbers,
    String? email,
    DateTime? createdAt,
    DateTime? updatedAt,
    Uint8List? avatar,
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
      ];
}




