import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
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

  // ── Credentials ───────────────────────────────────────────────────────
  //
  // Stored as a salted, stretched hash rather than the secret itself. The
  // Keystore-backed storage already resists another *app* reading it, but the
  // PIN protects a database of the user's SMS — a plaintext copy of it is the
  // one thing that turns a device compromise into "and they can also unlock
  // the app". Rows written by earlier versions are plaintext and are upgraded
  // in place the first time they validate; see [_verify].

  Future<void> setPin(String pin) async {
    await _storage.write(key: AppConstants.pinKey, value: _hash(pin));
    await setAuthType(AuthType.pin);
  }

  Future<void> setPattern(List<int> pattern) async {
    await _storage.write(
      key: AppConstants.patternKey,
      value: _hash(pattern.join(',')),
    );
    await setAuthType(AuthType.pattern);
  }

  Future<bool> validatePin(String pin) => _verify(AppConstants.pinKey, pin);

  Future<bool> validatePattern(List<int> pattern) =>
      _verify(AppConstants.patternKey, pattern.join(','));

  /// Whether a credential exists at all — used by the recovery flow, which
  /// must not offer to "reset" a PIN that was never set.
  Future<bool> hasCredential() async {
    final pin = await _storage.read(key: AppConstants.pinKey);
    if (pin != null && pin.isNotEmpty) return true;
    final pattern = await _storage.read(key: AppConstants.patternKey);
    return pattern != null && pattern.isNotEmpty;
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
    await _storage.delete(key: AppConstants.recoveryCodeKey);
  }

  /// «ادامه بدون رمز»: when true, the app never re-prompts auth setup on
  /// launch. Cleared automatically the moment a PIN/pattern is set.
  Future<void> setAuthSkipped(bool value) async {
    await _storage.write(
      key: AppConstants.authSkippedKey,
      value: value.toString(),
    );
  }

  Future<bool> isAuthSkipped() async {
    final value = await _storage.read(key: AppConstants.authSkippedKey);
    return value == 'true';
  }

  // ── Recovery code ─────────────────────────────────────────────────────
  //
  // A forgotten PIN used to be a permanent lockout: there is no account, no
  // server and no email to send a reset to, and the app deliberately holds the
  // only copy of the user's messages. The answer that fits an offline app is a
  // one-time code shown at setup, which the user writes down — the same shape
  // as a 2FA backup code.
  //
  // Only its hash is stored, so the code cannot be read back off the device by
  // anything that can read the storage; losing the written copy means it must
  // be regenerated from inside the app (Settings), which requires being
  // unlocked already.

  /// Mints a fresh recovery code, stores its hash and returns the plaintext.
  ///
  /// The caller MUST show it — this is the only moment it exists in readable
  /// form. Calling it again invalidates the previous code.
  Future<String> regenerateRecoveryCode() async {
    final code = _generateRecoveryCode();
    await _storage.write(
      key: AppConstants.recoveryCodeKey,
      // Normalized before hashing so the check can be forgiving about case
      // and the dashes the user may or may not type.
      value: _hash(_normalizeRecoveryCode(code)),
    );
    return code;
  }

  Future<bool> hasRecoveryCode() async {
    final stored = await _storage.read(key: AppConstants.recoveryCodeKey);
    return stored != null && stored.isNotEmpty;
  }

  /// True when [code] matches the stored recovery code. Case- and
  /// dash-insensitive: the user is reading it off a piece of paper.
  Future<bool> validateRecoveryCode(String code) async {
    final normalized = _normalizeRecoveryCode(code);
    if (normalized.isEmpty) return false;
    return _verify(AppConstants.recoveryCodeKey, normalized);
  }

  /// Characters that cannot be confused when hand-written: no O/0, I/1, S/5,
  /// B/8. A recovery code that is misread is a recovery code that does not
  /// work, which is worse than a slightly shorter alphabet.
  static const String _codeAlphabet = 'ACDEFGHJKLMNPQRTUVWXY34679';

  static String _generateRecoveryCode() {
    final random = Random.secure();
    final chars = List<String>.generate(
      12,
      (_) => _codeAlphabet[random.nextInt(_codeAlphabet.length)],
    );
    // Grouped for reading: ABCD-EFGH-JKLM.
    return '${chars.sublist(0, 4).join()}-'
        '${chars.sublist(4, 8).join()}-'
        '${chars.sublist(8).join()}';
  }

  static String _normalizeRecoveryCode(String code) =>
      code.toUpperCase().replaceAll(RegExp(r'[^A-Z0-9]'), '');

  // ── Hashing ───────────────────────────────────────────────────────────

  /// Marks a value as hashed. Anything without it is a plaintext secret
  /// written by an earlier version.
  static const String _hashPrefix = 'v2:';

  /// Rounds of SHA-256. A 4-digit PIN has 10 000 possibilities, so stretching
  /// is what makes an offline guess cost something; 60 k rounds is a few tens
  /// of milliseconds on a phone and is only ever run on an explicit unlock.
  static const int _rounds = 60000;

  static String _hash(String secret, {String? salt}) {
    final actualSalt = salt ?? _randomSalt();
    List<int> digest = utf8.encode('$actualSalt$secret');
    for (var i = 0; i < _rounds; i++) {
      digest = sha256.convert(digest).bytes;
    }
    return '$_hashPrefix$actualSalt:${base64Url.encode(digest)}';
  }

  static String _randomSalt() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// Compares [secret] against the value at [key], upgrading a legacy
  /// plaintext row to a hash on the way through.
  ///
  /// The upgrade happens on a *successful* match only — a wrong guess must
  /// never rewrite the stored credential.
  Future<bool> _verify(String key, String secret) async {
    final stored = await _storage.read(key: key);
    if (stored == null || stored.isEmpty) return false;

    if (!stored.startsWith(_hashPrefix)) {
      // Legacy plaintext (<= the version that introduced hashing).
      if (stored != secret) return false;
      await _storage.write(key: key, value: _hash(secret));
      return true;
    }

    final parts = stored.split(':');
    // 'v2', salt, hash — a malformed row is treated as no credential rather
    // than crashing the lock screen.
    if (parts.length != 3) return false;
    return _constantTimeEquals(stored, _hash(secret, salt: parts[1]));
  }

  /// Length-and-content comparison that does not return early on the first
  /// differing byte. The threat is modest here (an attacker with this much
  /// access has the storage anyway) but the cost is nil.
  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
