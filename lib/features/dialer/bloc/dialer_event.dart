import 'package:equatable/equatable.dart';
import '../services/native_call_service.dart';

abstract class DialerEvent extends Equatable {
  const DialerEvent();

  @override
  List<Object?> get props => [];
}

// ── Keypad events (موجود) ─────────────────────────────────────────────────

class DialerNumberPressed extends DialerEvent {
  final String number;
  const DialerNumberPressed(this.number);

  @override
  List<Object?> get props => [number];
}

/// Puts a whole number in the field at once.
///
/// Two callers, and both are things the keypad could not do before: pasting a
/// number copied from another app, and a `tel:` intent handed to us as the
/// phone's dialer («Call» on a number in a browser or a messenger). Typing a
/// number digit by digit because it was already on the clipboard is exactly the
/// friction this removes.
class DialerNumberSet extends DialerEvent {
  final String number;

  /// Append to what is already typed instead of replacing it — what «چسباندن»
  /// does mid-number.
  final bool append;

  const DialerNumberSet(this.number, {this.append = false});

  @override
  List<Object?> get props => [number, append];
}

class DialerNumberCleared extends DialerEvent {
  const DialerNumberCleared();
}

class DialerNumberDeleted extends DialerEvent {
  const DialerNumberDeleted();
}

class DialerLoadContacts extends DialerEvent {
  const DialerLoadContacts();
}

class DialerFilterContacts extends DialerEvent {
  final String query;
  const DialerFilterContacts(this.query);

  @override
  List<Object?> get props => [query];
}

// ── Call events (جدید — Step 3) ───────────────────────────────────────────

class MakeCall extends DialerEvent {
  /// SIM to dial from, already resolved by the UI (the picker cannot live in a
  /// BLoC — it needs a BuildContext). Null = let telecom honour the system's
  /// default voice SIM, which is the whole behaviour on a single-SIM phone.
  final int? subscriptionId;

  const MakeCall({this.subscriptionId});

  @override
  List<Object?> get props => [subscriptionId];
}

class EndCall extends DialerEvent {
  const EndCall();
}

class AnswerCall extends DialerEvent {
  const AnswerCall();
}

class RejectCall extends DialerEvent {
  const RejectCall();
}

class ToggleMute extends DialerEvent {
  const ToggleMute();
}

class ToggleSpeaker extends DialerEvent {
  const ToggleSpeaker();
}

class HoldCall extends DialerEvent {
  final bool hold;
  const HoldCall({this.hold = true});

  @override
  List<Object?> get props => [hold];
}

/// An in-call keypad key went down: start transmitting [digit] and add it to
/// [DialerState.dtmfDigits]. Always followed by [DtmfKeyUp].
class DtmfKeyDown extends DialerEvent {
  final String digit;
  const DtmfKeyDown(this.digit);

  @override
  List<Object?> get props => [digit];
}

/// The in-call keypad key was released (or the press was cancelled): stop the
/// tone [DtmfKeyDown] started.
class DtmfKeyUp extends DialerEvent {
  const DtmfKeyUp();
}

/// ادغام تماس فعال و تماس در انتظار در یک تماس کنفرانسی
class MergeCalls extends DialerEvent {
  const MergeCalls();
}

/// تعویض تماس فعال با تماس در انتظار
class SwapCalls extends DialerEvent {
  const SwapCalls();
}

/// Routes the call audio explicitly (گوشی / بلندگو / بلوتوث / هدست سیمی).
///
/// Separate from [ToggleSpeaker], which can only flip between the two built-in
/// outputs and therefore cannot reach a bluetooth headset at all.
class SelectAudioRoute extends DialerEvent {
  final CallAudioRoute route;
  const SelectAudioRoute(this.route);

  @override
  List<Object?> get props => [route];
}

/// Re-reads the live call state from telecom and drops the call UI when there
/// is no call. Fired on every app resume — the safety net under the event
/// stream, because a missed DISCONNECTED strands the user on a dead call
/// screen and only telecom knows the truth.
class SyncCallState extends DialerEvent {
  const SyncCallState();
}

/// «لغو» on the ended-call screen while «تماس مجدد خودکار» counts down, and
/// the back gesture there: the series ends and the screen goes.
class CancelAutoRedial extends DialerEvent {
  const CancelAutoRedial();
}

/// The countdown ran out — place the next attempt. Fired by the bloc's own
/// timer; nothing in the UI sends it.
class AutoRedialDue extends DialerEvent {
  const AutoRedialDue();
}

/// رویداد دریافتی از NativeCallService stream
class CallEventReceived extends DialerEvent {
  final CallInfo callInfo;
  const CallEventReceived(this.callInfo);

  @override
  List<Object?> get props => [callInfo.event, callInfo.phone];
}
