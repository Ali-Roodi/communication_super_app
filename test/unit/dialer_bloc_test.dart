import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/services/native_call_service.dart';
import 'package:communication_super_app/features/contacts/repositories/contact_repository.dart';
import 'package:communication_super_app/features/contacts/models/contact_model.dart';
import 'package:communication_super_app/features/contacts/models/phone_match.dart';

class _MockContactRepository extends Mock implements ContactRepository {}

class _MockNativeCallService extends Mock implements NativeCallService {}

void main() {
  late _MockContactRepository repo;
  late _MockNativeCallService callService;

  setUp(() {
    repo = _MockContactRepository();
    callService = _MockNativeCallService();

    // The bloc loads contacts and subscribes to the call-event stream in its
    // constructor; stub both so it can be built in isolation.
    when(() => repo.getAllContacts()).thenAnswer((_) async => <ContactModel>[]);
    when(
      () => repo.matchPhoneDigits(any(), any()),
    ).thenReturn(<PhoneMatch>[]);
    when(
      () => callService.callEvents,
    ).thenAnswer((_) => const Stream<CallInfo>.empty());
  });

  DialerBloc makeBloc() => DialerBloc(repo, callService: callService);

  // Small settle delay: number edits emit synchronously, but a 300ms debounce
  // timer also schedules a filter pass — we assert the immediate edit state.
  Future<void> settle() =>
      Future<void>.delayed(const Duration(milliseconds: 10));

  group('DialerBloc keypad editing', () {
    test('pressing digits appends to dialedNumber', () async {
      final bloc = makeBloc();
      bloc.add(const DialerNumberPressed('9'));
      bloc.add(const DialerNumberPressed('1'));
      bloc.add(const DialerNumberPressed('2'));
      await settle();
      expect(bloc.state.dialedNumber, '912');
      await bloc.close();
    });

    test('delete removes the last digit', () async {
      final bloc = makeBloc();
      bloc.add(const DialerNumberPressed('9'));
      bloc.add(const DialerNumberPressed('1'));
      await settle();
      bloc.add(const DialerNumberDeleted());
      await settle();
      expect(bloc.state.dialedNumber, '9');
      await bloc.close();
    });

    test('delete on empty number is a no-op', () async {
      final bloc = makeBloc();
      bloc.add(const DialerNumberDeleted());
      await settle();
      expect(bloc.state.dialedNumber, '');
      await bloc.close();
    });

    test('clear empties the number and matches', () async {
      final bloc = makeBloc();
      bloc.add(const DialerNumberPressed('9'));
      bloc.add(const DialerNumberPressed('1'));
      await settle();
      bloc.add(const DialerNumberCleared());
      await settle();
      expect(bloc.state.dialedNumber, '');
      expect(bloc.state.matchingNumbers, isEmpty);
      expect(bloc.state.isNumberInContacts, isFalse);
      await bloc.close();
    });
  });

  group('DialerBloc call lifecycle', () {
    test('incoming call event sets status + active phone', () async {
      final bloc = makeBloc();
      bloc.add(
        const CallEventReceived(
          CallInfo(event: NativeCallEvent.incoming, phone: '09120000000'),
        ),
      );
      await settle();
      expect(bloc.state.callStatus, CallStatus.incoming);
      expect(bloc.state.activePhone, '09120000000');
      await bloc.close();
    });

    test('disconnected event resets call state to idle', () async {
      final bloc = makeBloc();
      bloc.add(
        const CallEventReceived(
          CallInfo(event: NativeCallEvent.active, phone: '09120000000'),
        ),
      );
      await settle();
      expect(bloc.state.callStatus, CallStatus.active);

      bloc.add(
        const CallEventReceived(CallInfo(event: NativeCallEvent.disconnected)),
      );
      await settle();
      expect(bloc.state.callStatus, CallStatus.idle);
      expect(bloc.state.activePhone, '');
      expect(bloc.state.isMuted, isFalse);
      expect(bloc.state.isSpeakerOn, isFalse);
      await bloc.close();
    });

    test(
      'makeCall delegates to the call service and clears the keypad',
      () async {
        when(() => callService.makeCall(any())).thenAnswer((_) async {});
        final bloc = makeBloc();
        bloc.add(const DialerNumberPressed('9'));
        await settle();
        bloc.add(const MakeCall());
        await settle();
        verify(() => callService.makeCall('9')).called(1);
        expect(bloc.state.dialedNumber, '');
        await bloc.close();
      },
    );
  });
}
