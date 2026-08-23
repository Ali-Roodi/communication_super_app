import 'dart:async';

import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/call_history/bloc/call_log_bloc.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_event.dart';
import 'package:communication_super_app/features/call_history/bloc/call_log_state.dart';
import 'package:communication_super_app/features/call_history/models/call_log_model.dart';
import 'package:communication_super_app/features/call_history/repositories/call_log_repository.dart';
import 'package:communication_super_app/features/call_history/services/call_log_service.dart';

class _MockCallLogService extends Mock implements CallLogService {}

class _MockCallLogRepository extends Mock implements CallLogRepository {}

CallLogModel _log(String id) => CallLogModel(
  id: id,
  phoneNumber: '0912000$id',
  callType: CallType.incoming,
  timestamp: DateTime(2026, 1, 1, 12),
);

void main() {
  late _MockCallLogService service;
  late _MockCallLogRepository repo;

  setUpAll(() => registerFallbackValue(<CallLogModel>[]));

  setUp(() {
    service = _MockCallLogService();
    repo = _MockCallLogRepository();
    when(
      () => service.ensureSynced(forceRefresh: any(named: 'forceRefresh')),
    ).thenAnswer((_) async => false);
    // Name resolution is a pass-through in tests (no contacts).
    when(() => service.resolveContactNames(any())).thenAnswer(
      (inv) async => inv.positionalArguments.first as List<CallLogModel>,
    );
  });

  CallLogBloc build() => CallLogBloc(
    service: service,
    repository: repo,
    observeDeviceChanges: false,
  );

  blocTest<CallLogBloc, CallLogState>(
    'LoadCallLogs emits [Loading, Loaded] with hasMore=false for a short page',
    setUp: () {
      when(
        () => repo.getAllCallLogs(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => [_log('1'), _log('2')]);
    },
    build: build,
    act: (bloc) => bloc.add(const LoadCallLogs()),
    expect: () => [
      const CallLogLoading(),
      CallLogsLoaded([_log('1'), _log('2')], hasMore: false),
    ],
    verify: (_) {
      verify(() => service.ensureSynced()).called(1);
      // The whole table must never be read: only the paginated page.
      verifyNever(() => repo.getAllCallLogs());
    },
  );

  blocTest<CallLogBloc, CallLogState>(
    'LoadCallLogs paints the local mirror without waiting for the device sync',
    setUp: () {
      // The device half never answers — a slow provider, or a phone that is
      // simply busy on a cold start. «اخیر» must not wait for it: it used to,
      // behind a full-screen spinner, which is what made every launch look
      // like it was loading for a second or two.
      when(
        () => service.ensureSynced(forceRefresh: any(named: 'forceRefresh')),
      ).thenAnswer((_) => Completer<bool>().future);
      when(
        () => repo.getAllCallLogs(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => [_log('1')]);
    },
    build: build,
    act: (bloc) => bloc.add(const LoadCallLogs()),
    expect: () => [
      const CallLogLoading(),
      CallLogsLoaded([_log('1')], hasMore: false),
    ],
  );

  blocTest<CallLogBloc, CallLogState>(
    'an empty mirror stays loading until the device has been read once',
    setUp: () {
      when(
        () => repo.getAllCallLogs(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => <CallLogModel>[]);
    },
    build: build,
    act: (bloc) => bloc.add(const LoadCallLogs()),
    // «تماس اخیری وجود ندارد» must not flash over a phone whose calls are
    // still being imported — the empty state is only emitted once the device
    // pass has actually happened, and exactly once (no load/sync loop).
    expect: () => [const CallLogLoading(), const CallLogsLoaded([])],
  );

  blocTest<CallLogBloc, CallLogState>(
    'LoadMoreCallLogs appends the next page to the current list',
    setUp: () {
      when(
        () => repo.getAllCallLogs(
          limit: any(named: 'limit'),
          offset: any(named: 'offset'),
        ),
      ).thenAnswer((_) async => [_log('2')]);
    },
    build: build,
    seed: () => CallLogsLoaded([_log('1')], hasMore: true),
    act: (bloc) => bloc.add(const LoadMoreCallLogs()),
    expect: () => [
      CallLogsLoaded([_log('1'), _log('2')], hasMore: false),
    ],
  );

  blocTest<CallLogBloc, CallLogState>(
    'LoadMoreCallLogs is a no-op when hasMore is false',
    build: build,
    seed: () => CallLogsLoaded([_log('1')], hasMore: false),
    act: (bloc) => bloc.add(const LoadMoreCallLogs()),
    expect: () => const <CallLogState>[],
  );
}
