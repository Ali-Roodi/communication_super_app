import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/screens/call_history_screen.dart';
import 'package:flutter_test/flutter_test.dart';

CallLogModel _call(String id, String number, int minute, {int? sim}) =>
    CallLogModel(
      id: id,
      phoneNumber: number,
      callType: CallType.outgoing,
      timestamp: DateTime(2026, 10, 19, 14, minute),
      subscriptionId: sim,
    );

void main() {
  List<List<String>> runs(List<CallLogModel> logs) => [
    for (final run in callLogRuns(logs)) [for (final c in run) c.id],
  ];

  test('consecutive calls to one number on one SIM collapse into a run', () {
    expect(
      runs([
        _call('a', '09190961805', 30, sim: 10),
        _call('b', '+989190961805', 20, sim: 10),
      ]),
      [
        ['a', 'b'],
      ],
    );
  });

  test('a call on the other SIM starts a run of its own', () {
    // Found on the SM A336E: a SIM 2 call folded under a SIM 1 row, and the
    // row showed only «۱».
    expect(
      runs([
        _call('a', '09190961805', 30, sim: 10),
        _call('b', '09190961805', 25, sim: 13),
        _call('c', '09190961805', 20, sim: 13),
      ]),
      [
        ['a'],
        ['b', 'c'],
      ],
    );
  });

  test('another number or another day breaks the run', () {
    final yesterday = CallLogModel(
      id: 'd',
      phoneNumber: '09190961805',
      callType: CallType.outgoing,
      timestamp: DateTime(2026, 10, 18, 23, 59),
      subscriptionId: 10,
    );
    expect(
      runs([
        _call('a', '09190961805', 30, sim: 10),
        _call('b', '09120000000', 25, sim: 10),
        _call('c', '09190961805', 20, sim: 10),
        yesterday,
      ]),
      [
        ['a'],
        ['b'],
        ['c'],
        ['d'],
      ],
    );
  });
}
