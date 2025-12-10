import 'package:local_auth/local_auth.dart';
import 'package:communication_super_app/features/authentication/repositories/auth_repository.dart';

class AppLockService {
  final LocalAuthentication _localAuth = LocalAuthentication();
  final AuthRepository _authRepository = AuthRepository();
  bool _isLocked = false;

  bool get isLocked => _isLocked;

  Future<void> lock() async {
    _isLocked = true;
  }

  Future<void> unlock() async {
    _isLocked = false;
  }

  Future<bool> isBiometricAvailable() async {
    try {
      final isAvailable = await _localAuth.canCheckBiometrics;
      final isDeviceSupported = await _localAuth.isDeviceSupported();
      return isAvailable || isDeviceSupported;
    } catch (e) {
      return false;
    }
  }

  Future<List<BiometricType>> getAvailableBiometrics() async {
    try {
      return await _localAuth.getAvailableBiometrics();
    } catch (e) {
      return [];
    }
  }

  Future<bool> authenticateWithBiometric() async {
    try {
      final isAvailable = await isBiometricAvailable();
      if (!isAvailable) {
        return false;
      }

      final authenticated = await _localAuth.authenticate(
        localizedReason: 'لطفاً برای باز کردن قفل برنامه، احراز هویت کنید',
      );

      if (authenticated) {
        await unlock();
        await _authRepository.setAuthenticated(true);
      }

      return authenticated;
    } catch (e) {
      return false;
    }
  }

  Future<bool> authenticateWithPin(String pin) async {
    try {
      final isValid = await _authRepository.validatePin(pin);
      if (isValid) {
        await unlock();
        await _authRepository.setAuthenticated(true);
      }
      return isValid;
    } catch (e) {
      return false;
    }
  }
}

