import 'package:communication_super_app/core/edition/app_edition.dart';

/// How long a PIN is.
///
/// The commercial edition keeps the 4-digit app PIN it always had. The
/// editions with a secure section require **6 digits** for a new app PIN
/// (owner's decision, 1405/07/05). The secure section's own PIN is always
/// [secureLength].
///
/// The length of the PIN actually stored is recorded with it
/// ([AuthRepository.pinLength]); entry screens size themselves from that, so a
/// 4-digit PIN set before an activation keeps working until it is changed.
class PinPolicy {
  PinPolicy._();

  static const int standardLength = 4;
  static const int secureLength = 6;

  /// The length a NEW PIN must have in [edition].
  static int requiredFor(AppEdition edition) =>
      edition == AppEdition.commercial ? standardLength : secureLength;
}
