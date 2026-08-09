import 'package:equatable/equatable.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';
import 'package:communication_super_app/core/utils/persian_utils.dart';

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

  /// Name to show, falling back to the formatted phone number.
  String get displayName => (name != null && name!.isNotEmpty)
      ? name!
      : PersianUtils.displayPhone(phoneNumber);

  /// The canonical key for [phone] — `PhoneNormalizer.toNational`, the same
  /// `09xxxxxxxxx` form `messages.thread_id` and `blocked_numbers.normalized`
  /// use.
  ///
  /// It used to be a raw digits-only strip, and since this column is the
  /// favourites table's UNIQUE key that meant the *same person* could be starred
  /// twice: once from a call log where the carrier delivered `+989121234567` and
  /// once from Contacts where the number is saved `09121234567`. Two rows, two
  /// stars, and `isFavorite` answering false on whichever surface asked with the
  /// other form. DB v19 rewrites the rows written before this.
  /// Empty when [phone] holds no digits at all: `PhoneNormalizer` falls back to
  /// returning the trimmed input for a string it cannot parse, and without this
  /// guard «no-digits-here» would be stored as a starred "number". Callers treat
  /// empty as "not a number, do nothing".
  static String normalize(String phone) {
    if (!phone.contains(_anyDigit)) return '';
    return PhoneNormalizer.toNational(phone);
  }

  /// ASCII, Persian and Arabic-Indic digits — the same set `PhoneNormalizer`
  /// accepts.
  static final RegExp _anyDigit = RegExp(r'[\d۰-۹٠-٩]');

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
