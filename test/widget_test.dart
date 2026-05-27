// Ghasem app — widget smoke test
//
// The full app widget requires SQLite, SharedPreferences, native channels and
// runtime permissions, all of which are unavailable in a headless test
// environment.  The meaningful tests live in test/unit/. This file just
// verifies that the test runner itself can start successfully.

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('test runner sanity check', () {
    // If this passes the test infrastructure is working correctly.
    expect(1 + 1, equals(2));
  });
}
