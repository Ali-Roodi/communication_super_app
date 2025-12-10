import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import '../models/auth_type.dart';
import 'package:communication_super_app/core/constants/app_constants.dart';

class AuthRepository {
  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> setAuthType(AuthType type) async {
    await _storage.write(key: AppConstants.authTypeKey, value: type.value);
  }

  Future<AuthType> getAuthType() async {
    final value = await _storage.read(key: AppConstants.authTypeKey);
    return value != null ? AuthTypeExtension.fromString(value) : AuthType.none;
  }

  Future<void> setPin(String pin) async {
    await _storage.write(key: AppConstants.pinKey, value: pin);
    await setAuthType(AuthType.pin);
  }

  Future<String?> getPin() async {
    return await _storage.read(key: AppConstants.pinKey);
  }

  Future<void> setPattern(List<int> pattern) async {
    final patternString = pattern.join(',');
    await _storage.write(key: AppConstants.patternKey, value: patternString);
    await setAuthType(AuthType.pattern);
  }

  Future<List<int>?> getPattern() async {
    final patternString = await _storage.read(key: AppConstants.patternKey);
    if (patternString == null) return null;
    return patternString.split(',').map((e) => int.parse(e)).toList();
  }

  Future<bool> validatePin(String pin) async {
    final storedPin = await getPin();
    return storedPin == pin;
  }

  Future<bool> validatePattern(List<int> pattern) async {
    final storedPattern = await getPattern();
    if (storedPattern == null) return false;
    if (storedPattern.length != pattern.length) return false;
    for (int i = 0; i < storedPattern.length; i++) {
      if (storedPattern[i] != pattern[i]) return false;
    }
    return true;
  }

  Future<bool> isAuthenticated() async {
    final value = await _storage.read(key: AppConstants.isAuthenticatedKey);
    return value == 'true';
  }

  Future<void> setAuthenticated(bool value) async {
    await _storage.write(
      key: AppConstants.isAuthenticatedKey,
      value: value.toString(),
    );
  }

  Future<void> clearAuth() async {
    await _storage.delete(key: AppConstants.pinKey);
    await _storage.delete(key: AppConstants.patternKey);
    await _storage.delete(key: AppConstants.authTypeKey);
    await _storage.delete(key: AppConstants.isAuthenticatedKey);
  }
}


