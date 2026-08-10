import 'package:equatable/equatable.dart';

/// One keypad digit and the number holding it down calls.
///
/// [position] is the digit itself (2–9) — see [SpeedDialEntry.positions] for
/// why the other two keys are not assignable.
class SpeedDialEntry extends Equatable {
  final int position;
  final String phoneNumber;

  /// Who the number belonged to when it was assigned. Stored rather than
  /// resolved, so the keypad can say who it is about to call without reading
  /// the address book first, and so a deleted contact leaves a working key.
  final String? name;

  /// Device contact id, when it was assigned from one. Only used to open the
  /// contact page and to pick an avatar.
  final String? contactId;

  final DateTime updatedAt;

  const SpeedDialEntry({
    required this.position,
    required this.phoneNumber,
    this.name,
    this.contactId,
    required this.updatedAt,
  });

  /// The assignable keys. `۱` is voicemail on every phone ever made and `۰`
  /// types «+» — taking either would break a gesture people already know.
  static const List<int> positions = [2, 3, 4, 5, 6, 7, 8, 9];

  static bool isAssignable(int position) => positions.contains(position);

  /// What to show on a row: the saved name, or the number when there is none.
  String get displayName =>
      (name == null || name!.trim().isEmpty) ? phoneNumber : name!.trim();

  Map<String, dynamic> toMap() => {
    'position': position,
    'phone_number': phoneNumber,
    'name': name,
    'contact_id': contactId,
    'updated_at': updatedAt.millisecondsSinceEpoch,
  };

  factory SpeedDialEntry.fromMap(Map<String, dynamic> map) => SpeedDialEntry(
    position: map['position'] as int,
    phoneNumber: map['phone_number'] as String,
    name: map['name'] as String?,
    contactId: map['contact_id'] as String?,
    updatedAt: DateTime.fromMillisecondsSinceEpoch(
      map['updated_at'] as int? ?? 0,
    ),
  );

  @override
  List<Object?> get props => [position, phoneNumber, name, contactId];
}
