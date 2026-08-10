import 'package:equatable/equatable.dart';

import 'contact_model.dart';

/// One phone number of a contact that matched a dialled/typed query.
///
/// A contact with several numbers produces one [PhoneMatch] per matching
/// number, so the suggestion row can show *the number that was searched for*
/// instead of the contact's first number.
class PhoneMatch extends Equatable {
  final ContactModel contact;

  /// The matching number, as stored in the address book.
  final String number;

  /// Digits of [number] with everything else stripped — what the query was
  /// matched against, reused to highlight the typed part.
  final String digits;

  /// Index of the query inside [digits], or -1 when the match came from
  /// somewhere else (a name search).
  final int matchStart;

  /// Length of the matched query in [digits].
  final int matchLength;

  /// Index into [ContactModel.name] where the typed digits matched as **T9**
  /// (the keypad's letters), or -1 when the hit came from the number.
  ///
  /// Kept in the original string's indices so the row can highlight the letters
  /// the user actually typed — the same rule [SearchText.matchRange] follows.
  final int nameStart;

  /// Length of the T9 hit inside [ContactModel.name].
  final int nameLength;

  /// Whether this row is here because the name was typed on the keypad rather
  /// than the number.
  bool get isT9 => nameStart >= 0;

  const PhoneMatch({
    required this.contact,
    required this.number,
    required this.digits,
    this.matchStart = -1,
    this.matchLength = 0,
    this.nameStart = -1,
    this.nameLength = 0,
  });

  @override
  List<Object?> get props => [
    contact.id,
    number,
    matchStart,
    matchLength,
    nameStart,
    nameLength,
  ];
}
