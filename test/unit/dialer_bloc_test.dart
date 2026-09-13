import 'package:flutter_test/flutter_test.dart';
import 'package:mocktail/mocktail.dart';

import 'package:communication_super_app/features/dialer/bloc/dialer_bloc.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_event.dart';
import 'package:communication_super_app/features/dialer/bloc/dialer_state.dart';
import 'package:communication_super_app/features/dialer/services/auto_redial_policy.dart';
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
    when(() => repo.matchPhoneDigits(any(), any())).thenReturn(<PhoneMatch>[]);
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

    test(
      'a call from an unsaved number does NOT inherit the previous name',
      () async {
        final bloc = makeBloc();
        bloc.add(
          const CallEventReceived(
            CallInfo(
              event: NativeCallEvent.incoming,
              phone: '09120000000',
              name: 'ایمان',
              subscriptionId: 2,
            ),
          ),
        );
        await settle();
        expect(bloc.state.activeName, 'ایمان');
        expect(bloc.state.activeSubscriptionId, 2);

        bloc.add(
          const CallEventReceived(
            CallInfo(event: NativeCallEvent.disconnected),
          ),
        );
        await settle();
        expect(bloc.state.activeName, isNull);
        expect(bloc.state.activeSubscriptionId, isNull);

        // The next caller has no contact and telecom reports no SIM. `copyWith`
        // reads null as "leave it alone", so without the explicit clears this
        // screen named the *previous* caller and badged the previous card.
        bloc.add(
          const CallEventReceived(
            CallInfo(event: NativeCallEvent.incoming, phone: '09351111111'),
          ),
        );
        await settle();
        expect(bloc.state.activePhone, '09351111111');
        expect(bloc.state.activeName, isNull);
        expect(bloc.state.activeSubscriptionId, isNull);
        await bloc.close();
      },
    );

    test(
      'a deleted contact stops naming the call, without a disconnect between',
      () async {
        final bloc = makeBloc();
        bloc.add(
          const CallEventReceived(
            CallInfo(
              event: NativeCallEvent.incoming,
              phone: '09107902209',
              name: 'ایمان',
            ),
          ),
        );
        await settle();
        expect(bloc.state.activeName, 'ایمان');

        // Same number, contact since deleted: the native PhoneLookup answers
        // with nothing, and that answer has to win.
        bloc.add(
          const CallEventReceived(
            CallInfo(event: NativeCallEvent.active, phone: '09107902209'),
          ),
        );
        await settle();
        expect(bloc.state.activeName, isNull);
        await bloc.close();
      },
    );

    test(
      'an event that names nobody leaves a live call\'s identity alone',
      () async {
        final bloc = makeBloc();
        bloc.add(
          const CallEventReceived(
            CallInfo(
              event: NativeCallEvent.incoming,
              phone: '09120000000',
              name: 'ایمان',
              subscriptionId: 1,
            ),
          ),
        );
        await settle();
        // AUDIO_STATE and hold changes carry no number: they are about the
        // call, not about who is on it.
        bloc.add(
          const CallEventReceived(CallInfo(event: NativeCallEvent.onHold)),
        );
        await settle();
        expect(bloc.state.activeName, 'ایمان');
        expect(bloc.state.activeSubscriptionId, 1);
        await bloc.close();
      },
    );

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

  /// «تماس مجدد خودکار». Every case here is a rule about when the phone may
  /// dial by itself — the feature is only safe if it is narrow.
  group('DialerBloc auto redial', () {
    const dialling = CallInfo(
      event: NativeCallEvent.ringing,
      phone: '+989120000000',
      subscriptionId: 2,
    );
    const busy = CallInfo(
      event: NativeCallEvent.disconnected,
      phone: '+989120000000',
      disconnectCause: CallDisconnectCause.busy,
    );

    setUp(() {
      AutoRedialPolicy.enabled = true;
      AutoRedialPolicy.maxAttempts = 2;
      AutoRedialPolicy.delay = const Duration(milliseconds: 40);
      when(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      ).thenAnswer((_) async {});
    });

    tearDown(() {
      AutoRedialPolicy.enabled = false;
      AutoRedialPolicy.maxAttempts = AutoRedialPolicy.defaultAttempts;
      AutoRedialPolicy.delay = AutoRedialPolicy.defaultDelay;
    });

    Future<void> countdown() =>
        Future<void>.delayed(const Duration(milliseconds: 80));

    test('a busy outgoing call is dialled again on the same SIM', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();

      final redial = bloc.state.autoRedial;
      expect(bloc.state.callStatus, CallStatus.idle);
      expect(redial, isNotNull);
      expect(redial!.attempt, 1);
      expect(redial.maxAttempts, 2);
      expect(redial.phone, '+989120000000');
      expect(redial.subscriptionId, 2);
      expect(redial.isCountingDown, isTrue);
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );

      await countdown();
      verify(
        () => callService.makeCall('+989120000000', subscriptionId: 2),
      ).called(1);
      // Placed, telecom yet to answer.
      expect(bloc.state.autoRedial?.isCountingDown, isFalse);
      await bloc.close();
    });

    test('the series stops after «تعداد تلاش‌ها»', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();
      await countdown(); // attempt 1 placed
      bloc.add(const CallEventReceived(dialling)); // our own attempt ringing
      await settle();
      expect(bloc.state.autoRedial?.attempt, 1);
      bloc.add(const CallEventReceived(busy));
      await settle();
      expect(bloc.state.autoRedial?.attempt, 2);
      await countdown(); // attempt 2 placed
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();

      expect(
        bloc.state.autoRedial,
        isNull,
        reason: 'two attempts were allowed',
      );
      await countdown();
      verify(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      ).called(2);
      await bloc.close();
    });

    test('off by default: nothing is redialled', () async {
      AutoRedialPolicy.enabled = false;
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await countdown();
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );
      await bloc.close();
    });

    test(
      'a call that connected is never redialled, however it ended',
      () async {
        final bloc = makeBloc();
        bloc.add(const CallEventReceived(dialling));
        bloc.add(
          CallEventReceived(
            CallInfo(
              event: NativeCallEvent.active,
              phone: '+989120000000',
              connectedAt: DateTime.now(),
            ),
          ),
        );
        bloc.add(
          CallEventReceived(
            CallInfo(
              event: NativeCallEvent.disconnected,
              phone: '+989120000000',
              disconnectCause: CallDisconnectCause.remote,
              connectedAt: DateTime.now(),
            ),
          ),
        );
        await settle();
        expect(bloc.state.autoRedial, isNull);
        await bloc.close();
      },
    );

    test('hanging up while dialling ends it — no redial', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      await settle();
      when(() => callService.endCall()).thenAnswer((_) async {});
      bloc.add(const EndCall());
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000000',
            disconnectCause: CallDisconnectCause.local,
          ),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await countdown();
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );
      await bloc.close();
    });

    test('a missed or rejected incoming call is not an attempt', () async {
      final bloc = makeBloc();
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.incoming,
            phone: '+989120000000',
            direction: 'incoming',
          ),
        ),
      );
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000000',
            direction: 'incoming',
            disconnectCause: CallDisconnectCause.missed,
          ),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await bloc.close();
    });

    test('«لغو» stops the countdown before it dials', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();
      expect(bloc.state.autoRedial, isNotNull);
      bloc.add(const CancelAutoRedial());
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await countdown();
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );
      await bloc.close();
    });

    test('an incoming call during the countdown ends the series', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.incoming,
            phone: '+989120000001',
            direction: 'incoming',
          ),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      expect(bloc.state.callStatus, CallStatus.incoming);
      await countdown();
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );
      await bloc.close();
    });

    test('a number dialled by hand during the countdown wins', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      await settle();
      // Every other screen dials through NativeCallService directly, so the
      // bloc only learns about it from telecom's RINGING for another number.
      bloc.add(
        const CallEventReceived(
          CallInfo(event: NativeCallEvent.ringing, phone: '+989120000009'),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await countdown();
      verifyNever(
        () => callService.makeCall(
          any(),
          subscriptionId: any(named: 'subscriptionId'),
        ),
      );
      await bloc.close();
    });

    test('the teardown safety nets keep the series alive', () async {
      // CALLS_CHANGED with zero calls and SyncCallState both wind the call
      // state back to idle; neither is news about the redial.
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(const CallEventReceived(busy));
      bloc.add(
        const CallEventReceived(
          CallInfo(event: NativeCallEvent.callsChanged, callCount: 0),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNotNull);
      await countdown();
      verify(
        () => callService.makeCall('+989120000000', subscriptionId: 2),
      ).called(1);
      await bloc.close();
    });

    test('a first DISCONNECTED with no cause waits for the second', () async {
      // Traced on the device: telecom's state change arrives with the cause
      // still UNKNOWN, and the real one (busy / local) follows a beat later
      // from onCallRemoved — after the first event has wound the status back
      // to idle.
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000000',
            disconnectCause: CallDisconnectCause.unknown,
          ),
        ),
      );
      await settle();
      expect(bloc.state.callStatus, CallStatus.idle);
      expect(bloc.state.autoRedial, isNull);
      bloc.add(const CallEventReceived(busy));
      await settle();
      expect(bloc.state.autoRedial?.attempt, 1);
      await bloc.close();
    });

    test('a causeless DISCONNECTED followed by LOCAL is a hang-up', () async {
      final bloc = makeBloc();
      bloc.add(const CallEventReceived(dialling));
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000000',
            disconnectCause: CallDisconnectCause.unknown,
          ),
        ),
      );
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000000',
            disconnectCause: CallDisconnectCause.local,
          ),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      // …and the undecided flag did not leak into a later, unrelated call.
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.incoming,
            phone: '+989120000001',
            direction: 'incoming',
          ),
        ),
      );
      bloc.add(
        const CallEventReceived(
          CallInfo(
            event: NativeCallEvent.disconnected,
            phone: '+989120000001',
            direction: 'incoming',
            disconnectCause: CallDisconnectCause.missed,
          ),
        ),
      );
      await settle();
      expect(bloc.state.autoRedial, isNull);
      await bloc.close();
    });

    test(
      'the duplicate DISCONNECTEDs of one teardown keep the series',
      () async {
        // The busy-line trace from the SM-A336E: one hang-up, three events —
        // the state change (status ringing → «redial»), then onCallRemoved and
        // republishCurrent with the status already idle. The second one used to
        // wipe the countdown the first had started.
        final bloc = makeBloc();
        bloc.add(const CallEventReceived(dialling));
        bloc.add(const CallEventReceived(busy));
        bloc.add(const CallEventReceived(busy));
        bloc.add(const CallEventReceived(busy));
        await settle();
        expect(bloc.state.autoRedial?.attempt, 1);
        expect(bloc.state.autoRedial?.isCountingDown, isTrue);
        await countdown();
        verify(
          () => callService.makeCall('+989120000000', subscriptionId: 2),
        ).called(1);
        await bloc.close();
      },
    );
  });
}
