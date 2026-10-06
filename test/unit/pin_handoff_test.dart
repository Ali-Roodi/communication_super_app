import 'package:communication_super_app/core/services/pin_handoff.dart';
import 'package:flutter_test/flutter_test.dart';

/// «پیام رمز جدید» used to ask for the same PIN twice — the app lock, then
/// the secure section behind it. The lock now hands the PIN it took to that
/// one launch; these pin down how little that hand-off may do.
void main() {
  final handoff = PinHandoff.instance;
  var clock = DateTime(2026, 10, 6, 10);

  // The clock only moves forward, across tests too.
  setUp(() {
    clock = clock.add(const Duration(hours: 1));
    handoff.now = () => clock;
  });

  // Leave nothing behind for the next test: claim, then let it lapse.
  tearDown(() {
    handoff.claim((_) {});
    clock = clock.add(const Duration(minutes: 1));
    handoff.offer('x');
    clock = clock.add(const Duration(minutes: 1));
  });

  void later(Duration d) => clock = clock.add(d);
  const past = Duration(seconds: 16);

  test('a PIN offered just before is claimed once', () {
    handoff.offer('731946');
    later(const Duration(seconds: 3));
    final got = <String>[];
    handoff.claim(got.add);
    handoff.claim(got.add); // the second waits; nothing more is offered
    later(past);
    expect(got, ['731946']);
  });

  test('a claim waits for the lock screen to be answered', () {
    final got = <String>[];
    handoff.claim(got.add); // the notification arrived under the lock screen
    later(const Duration(seconds: 5));
    handoff.offer('258036');
    expect(got, ['258036']);
  });

  test('an unclaimed PIN is forgotten', () {
    handoff.offer('731946');
    later(past);
    final got = <String>[];
    handoff.claim(got.add);
    expect(got, isEmpty);
  });

  test('a claim nobody answers lapses', () {
    final got = <String>[];
    handoff.claim(got.add);
    later(past);
    handoff.offer('731946'); // a later, unrelated unlock
    expect(got, isEmpty);
  });
}
