import 'package:communication_super_app/features/secure/services/secure_unread_badge.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// The lock icon's count (mentor's item 5): what waits in the native queues
/// plus what the section last saw unread — kept until the messages are seen,
/// not until the notification goes.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  var waiting = 0;
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    waiting = 0;
    SecureUnreadBadge.debugSetPending(() async => waiting);
  });

  test('arrivals not yet drained are counted', () async {
    waiting = 2;
    await SecureUnreadBadge.refresh();
    expect(SecureUnreadBadge.count.value, 2);
  });

  test('a drained message stays counted until it is seen', () async {
    waiting = 2;
    await SecureUnreadBadge.refresh();
    // The section opened: the queue went into secure.db, still unread.
    waiting = 0;
    await SecureUnreadBadge.remember(2);
    expect(SecureUnreadBadge.count.value, 2);
    // A new one arrives while the section is shut again.
    waiting = 1;
    await SecureUnreadBadge.refresh();
    expect(SecureUnreadBadge.count.value, 3);
    // Read in the section.
    waiting = 0;
    await SecureUnreadBadge.remember(0);
    expect(SecureUnreadBadge.count.value, 0);
  });

  test('survives a restart: only the count is kept', () async {
    await SecureUnreadBadge.remember(4);
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getKeys(), {SecureUnreadBadge.prefsKey});
    expect(prefs.getInt(SecureUnreadBadge.prefsKey), 4);
  });

  test('a reset section has nothing unread', () async {
    await SecureUnreadBadge.remember(4);
    await SecureUnreadBadge.forget();
    expect(SecureUnreadBadge.count.value, 0);
  });
}
