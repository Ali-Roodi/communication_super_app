enum AuthType {
  pin,
  pattern,
  none,
}

extension AuthTypeExtension on AuthType {
  String get value {
    switch (this) {
      case AuthType.pin:
        return 'pin';
      case AuthType.pattern:
        return 'pattern';
      case AuthType.none:
        return 'none';
    }
  }

  static AuthType fromString(String value) {
    switch (value) {
      case 'pin':
        return AuthType.pin;
      case 'pattern':
        return AuthType.pattern;
      default:
        return AuthType.none;
    }
  }
}









