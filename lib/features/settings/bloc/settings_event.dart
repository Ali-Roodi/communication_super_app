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

/// Switches every date display and date picker between the Jalali and
/// Gregorian calendars.
class SetCalendarType extends SettingsEvent {
  final CalendarType calendarType;
  const SetCalendarType(this.calendarType);

  @override
  List<Object?> get props => [calendarType];
}
