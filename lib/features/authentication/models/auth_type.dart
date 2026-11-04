enum AuthType { pin, none }

extension AuthTypeExtension on AuthType {
  String get value {
    switch (this) {
      case AuthType.pin:
        return 'pin';
      case AuthType.none:
        return 'none';
    }
  }

  static AuthType fromString(String value) {
    switch (value) {
      case 'pin':
        return AuthType.pin;
      default:
        return AuthType.none;
    }
  }
}
