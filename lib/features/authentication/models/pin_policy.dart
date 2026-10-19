/// How long a PIN is.
///
/// The **app PIN** is 4 digits in every edition (owner's decision,
/// 1405/07/27). The secure section has its own PIN, always [secureLength]
/// digits — it guards the data, the app PIN only the app.
///
/// The length of the app PIN actually stored is recorded with it
/// ([AuthRepository.pinLength]); entry screens size themselves from that.
class PinPolicy {
  PinPolicy._();

  static const int appLength = 4;
  static const int secureLength = 6;
}
