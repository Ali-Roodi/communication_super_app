import 'package:equatable/equatable.dart';
import 'settings_state.dart';

abstract class SettingsEvent extends Equatable {
  const SettingsEvent();

  @override
  List<Object?> get props => [];
}

class LoadSettings extends SettingsEvent {
  const LoadSettings();
}

class SetBoolSetting extends SettingsEvent {
  final BoolSetting key;
  final bool value;
  const SetBoolSetting(this.key, this.value);

  @override
  List<Object?> get props => [key, value];
}

class SetTtyMode extends SettingsEvent {
  final TtyMode mode;
  const SetTtyMode(this.mode);

  @override
  List<Object?> get props => [mode];
}

/// Switches every date display and date picker between the Jalali and
/// Gregorian calendars.
class SetCalendarType extends SettingsEvent {
  final CalendarType calendarType;
  const SetCalendarType(this.calendarType);

  @override
  List<Object?> get props => [calendarType];
}

class UpdateQuickReply extends SettingsEvent {
  final int index;
  final String text;
  const UpdateQuickReply(this.index, this.text);

  @override
  List<Object?> get props => [index, text];
}
