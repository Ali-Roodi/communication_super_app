import 'package:flutter_test/flutter_test.dart';
import 'package:communication_super_app/core/utils/phone_normalizer.dart';

void main() {
  group('PhoneNormalizer.toNational / toThreadId', () {
    // ── Canonical output ──────────────────────────────────────────────────────
    const national = '09190961805';

    test('E.164 (+98…) → national', () {
      expect(PhoneNormalizer.toNational('+989190961805'), national);
    });

    test('00+country-code (0098…) → national', () {
      expect(PhoneNormalizer.toNational('00989190961805'), national);
    });

    test('country-code only (98…, 12 digits) → national', () {
      expect(PhoneNormalizer.toNational('989190961805'), national);
    });

    test('national (09…, 11 digits) → unchanged', () {
      expect(PhoneNormalizer.toNational('09190961805'), national);
    });

    test('missing leading zero (9…, 10 digits) → national', () {
      expect(PhoneNormalizer.toNational('9190961805'), national);
    });

    // ── Separator stripping ───────────────────────────────────────────────────
    test('spaces stripped', () {
      expect(PhoneNormalizer.toNational('0919 096 1805'), national);
    });

    test('dashes stripped', () {
      expect(PhoneNormalizer.toNational('0919-096-1805'), national);
    });

    test('E.164 with spaces stripped', () {
      expect(PhoneNormalizer.toNational('+98 919 096 1805'), national);
    });

    // ── Persian / Arabic digit conversion ─────────────────────────────────────
    test('Persian digits (۰–۹) → ASCII', () {
      expect(PhoneNormalizer.toNational('۰۹۱۹۰۹۶۱۸۰۵'), national);
    });

    test('Arabic-Indic digits (٠–٩) → ASCII', () {
      expect(PhoneNormalizer.toNational('٠٩١٩٠٩٦١٨٠٥'), national);
    });

    test('E.164 with Persian digits → national', () {
      expect(PhoneNormalizer.toNational('+۹۸۹۱۹۰۹۶۱۸۰۵'), national);
    });

    // ── toThreadId == toNational ──────────────────────────────────────────────
    test('toThreadId delegates to toNational', () {
      expect(PhoneNormalizer.toThreadId('+989190961805'), national);
      expect(PhoneNormalizer.toThreadId('00989190961805'), national);
      expect(PhoneNormalizer.toThreadId('09190961805'), national);
    });

    // ── Unknown / short codes ─────────────────────────────────────────────────
    test('short code returns digit-only fallback', () {
      // A 4-digit short code doesn't match any Iranian pattern → digits only
      expect(PhoneNormalizer.toNational('1234'), '1234');
    });

    test('empty string returns empty', () {
      expect(PhoneNormalizer.toNational(''), '');
    });
  });

  // ── sameNumber ──────────────────────────────────────────────────────────────
  group('PhoneNormalizer.sameNumber', () {
    test('identical strings → true', () {
      expect(PhoneNormalizer.sameNumber('09120000000', '09120000000'), isTrue);
    });

    test('E.164 vs national → true', () {
      expect(PhoneNormalizer.sameNumber('+989120000000', '09120000000'), isTrue);
    });

    test('00-prefix vs national → true', () {
      expect(PhoneNormalizer.sameNumber('00989120000000', '09120000000'), isTrue);
    });

    test('country-code vs national → true', () {
      expect(PhoneNormalizer.sameNumber('989120000000', '09120000000'), isTrue);
    });

    test('missing-zero vs national → true', () {
      expect(PhoneNormalizer.sameNumber('9120000000', '09120000000'), isTrue);
    });

    test('different numbers → false', () {
      expect(PhoneNormalizer.sameNumber('09120000000', '09130000000'), isFalse);
    });
  });

  // ── normalize alias ──────────────────────────────────────────────────────────
  group('PhoneNormalizer.normalize', () {
    test('alias of toNational', () {
      const number = '+989190961805';
      expect(PhoneNormalizer.normalize(number),
          equals(PhoneNormalizer.toNational(number)));
    });
  });
}
