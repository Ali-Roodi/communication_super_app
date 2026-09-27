import 'dart:convert';

import 'package:communication_super_app/core/utils/blake3.dart';

/// The activation code that unlocks the inter-organizational edition.
///
/// **MIRROR of the mentor's Windows code generator** — and of `Activation.java`
/// in the earlier S2MS app, which is what that generator was written against.
/// The format is kept exactly (owner's decision); change nothing here without
/// the generator changing with it, or every code it issues stops working:
///
/// 1. The device shows its **device code**: BLAKE3 of the ANDROID_ID's bytes,
///    first 3 bytes, lowercase hex — 6 characters.
/// 2. The mentor types it into the Windows app, which interleaves it with the
///    app id `111111` — `d0 1 d1 1 d2 1 d3 1 d4 1 d5 1`, 12 characters — and
///    answers with the **activation code**: BLAKE3 of that string, first 5
///    bytes, lowercase hex — 10 characters.
/// 3. This app computes the same thing and compares.
///
/// No server is involved, which is the point — and also the limit: the whole
/// derivation is in this binary, so it keeps honest users honest and cannot
/// stop someone who reverse-engineers the APK. That trade was made knowingly;
/// see `docs/architecture/editions.md`.
class ActivationCode {
  ActivationCode._();

  /// `Activation.getConstantAppId()`.
  static const String appId = '111111';

  /// `Activation.CODE_LENGTH / 2` bytes → 6 hex characters.
  static const int deviceCodeLength = 6;

  /// `hexdigest(5)` → 10 hex characters.
  static const int activationCodeLength = 10;

  static final RegExp _hex = RegExp(r'^[0-9a-f]+$');

  /// The device code for [androidId], as the device displays it.
  ///
  /// `String.getBytes()` in the Java original is UTF-8 on Android; an
  /// ANDROID_ID is ASCII hex, where every encoding agrees anyway.
  static String deviceCodeFor(String androidId) => Blake3.hexDigest(
    utf8.encode(androidId),
    outputLength: deviceCodeLength ~/ 2,
  );

  /// The activation code the Windows app issues for [deviceCode].
  static String activationCodeFor(String deviceCode) {
    if (deviceCode.length != deviceCodeLength) {
      // Activation.checkCode answers false here (index out of range); refusing
      // to produce a code at all is the same outcome, stated.
      throw ArgumentError.value(
        deviceCode,
        'deviceCode',
        'must be 6 characters',
      );
    }
    final combined = StringBuffer();
    for (var i = 0; i < deviceCodeLength; i++) {
      combined
        ..write(deviceCode[i])
        ..write(appId[i]);
    }
    return Blake3.hexDigest(
      utf8.encode(combined.toString()),
      outputLength: activationCodeLength ~/ 2,
    );
  }

  /// [input] as a canonical activation code, or null when it cannot be one.
  ///
  /// The code is read out over the phone and typed by hand, so the reading is
  /// forgiving about everything that is not the code itself: spaces, dashes,
  /// letter case, bidi/ZWNJ marks a Persian keyboard slips in, and Persian or
  /// Arabic-Indic digits. The Java original compared case-sensitively against
  /// lowercase hex — [normalize] produces exactly that.
  static String? normalize(String input) {
    final out = StringBuffer();
    for (final rune in input.runes) {
      if (rune >= 0x06F0 && rune <= 0x06F9) {
        out.writeCharCode(0x30 + rune - 0x06F0); // ۰-۹
      } else if (rune >= 0x0660 && rune <= 0x0669) {
        out.writeCharCode(0x30 + rune - 0x0660); // ٠-٩
      } else if (_isIgnorable(rune)) {
        continue;
      } else {
        out.writeCharCode(rune);
      }
    }
    final code = out.toString().toLowerCase();
    if (code.length != activationCodeLength || !_hex.hasMatch(code)) {
      return null;
    }
    return code;
  }

  /// Whether [input] is the activation code for [deviceCode].
  static bool matches({required String deviceCode, required String input}) {
    final code = normalize(input);
    if (code == null || deviceCode.length != deviceCodeLength) return false;
    return _constantTimeEquals(code, activationCodeFor(deviceCode));
  }

  static bool _isIgnorable(int rune) =>
      rune == 0x20 || // space
      rune == 0x09 ||
      rune == 0x0A ||
      rune == 0x0D ||
      rune == 0x2D || // -
      rune == 0x5F || // _
      rune == 0xA0 || // no-break space
      rune == 0x200C || // ZWNJ
      rune == 0x200E || // LRM
      rune == 0x200F || // RLM
      (rune >= 0x202A && rune <= 0x202E) ||
      (rune >= 0x2066 && rune <= 0x2069);

  static bool _constantTimeEquals(String a, String b) {
    if (a.length != b.length) return false;
    var diff = 0;
    for (var i = 0; i < a.length; i++) {
      diff |= a.codeUnitAt(i) ^ b.codeUnitAt(i);
    }
    return diff == 0;
  }
}
