import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/services/sms_service.dart';

/// Covers the in-memory deduplication window (DESIGN_DECISIONS D4): the same SMS
/// delivered twice within the window is dropped, while distinct messages and the
/// same content at a different timestamp are not.
void main() {
  // SmsService constructs plugin singletons (telephony, notifications) in its
  // field initializers, which require an initialized binding.
  TestWidgetsFlutterBinding.ensureInitialized();

  const ts = 1700000000000;

  test('the second identical delivery within the window is a duplicate', () {
    final sms = SmsService();
    expect(sms.isDuplicateForTest('09120000000', 'سلام', ts), isFalse);
    expect(sms.isDuplicateForTest('09120000000', 'سلام', ts), isTrue);
  });

  test('different formats of the same number are deduplicated together', () {
    final sms = SmsService();
    expect(sms.isDuplicateForTest('+989120000000', 'سلام', ts), isFalse);
    // National form of the same number + same body/timestamp -> duplicate.
    expect(sms.isDuplicateForTest('09120000000', 'سلام', ts), isTrue);
  });

  test('different body or timestamp is not a duplicate', () {
    final sms = SmsService();
    expect(sms.isDuplicateForTest('09120000000', 'سلام', ts), isFalse);
    expect(sms.isDuplicateForTest('09120000000', 'خداحافظ', ts), isFalse);
    expect(sms.isDuplicateForTest('09120000000', 'سلام', ts + 1), isFalse);
  });
}
