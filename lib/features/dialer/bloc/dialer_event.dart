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
  const MakeCall();
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

class SendDtmf extends DialerEvent {
  final String digit;
  const SendDtmf(this.digit);

  @override
  List<Object?> get props => [digit];
}

/// ادغام تماس فعال و تماس در انتظار در یک تماس کنفرانسی
class MergeCalls extends DialerEvent {
  const MergeCalls();
}

/// تعویض تماس فعال با تماس در انتظار
class SwapCalls extends DialerEvent {
  const SwapCalls();
}

/// رویداد دریافتی از NativeCallService stream
class CallEventReceived extends DialerEvent {
  final CallInfo callInfo;
  const CallEventReceived(this.callInfo);

  @override
  List<Object?> get props => [callInfo.event, callInfo.phone];
}
