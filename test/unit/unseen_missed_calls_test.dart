import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/call_history/services/unseen_missed_calls.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _MockRepository extends Mock implements CallLogRepository {}

void main() {
  final moment = DateTime.fromMillisecondsSinceEpoch(1000000);
  late _MockRepository repository;
  late UnseenMissedCalls unseen;

  setUp(() {
    repository = _MockRepository();
    unseen = UnseenMissedCalls(repository: repository, now: () => moment);
  });

  test('the first read counts nothing and starts from now', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await unseen.count(), 0);
    verifyNever(() => repository.countMissedSince(any()));
    final prefs = await SharedPreferences.getInstance();
    expect(prefs.getInt(UnseenMissedCalls.seenAtKey), 1000000);
  });

  test('counts from the stored moment', () async {
    SharedPreferences.setMockInitialValues({UnseenMissedCalls.seenAtKey: 500});
    when(() => repository.countMissedSince(500)).thenAnswer((_) async => 3);
    expect(await unseen.count(), 3);
  });

  test('marking them seen moves the moment', () async {
    SharedPreferences.setMockInitialValues({UnseenMissedCalls.seenAtKey: 500});
    when(
      () => repository.countMissedSince(1000000),
    ).thenAnswer((_) async => 0);
    await unseen.markSeen();
    expect(await unseen.count(), 0);
    verify(() => repository.countMissedSince(1000000)).called(1);
  });
}
