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
      () => service.getCallLogs(forceRefresh: any(named: 'forceRefresh')),
    ).thenAnswer((_) async => <CallLogModel>[]);
    // Name resolution is a pass-through in tests (no contacts).
    when(() => service.resolveContactNames(any())).thenAnswer(
      (inv) async => inv.positionalArguments.first as List<CallLogModel>,
    );
  });

  CallLogBloc build() => CallLogBloc(service: service, repository: repo);

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
      verify(() => service.getCallLogs()).called(1);
    },
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
