import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'settings_event.dart';
import 'settings_state.dart';

/// All app settings (except theme, which lives in ThemeBloc) persisted to
/// SharedPreferences. Keys are prefixed with `set_`.
class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  static const _prefix = 'set_';
  static const _ttyKey = '${_prefix}tty_mode';
  static const _calendarKey = '${_prefix}calendar_type';
  static const _quickKey = '${_prefix}quick_replies';

  SettingsBloc() : super(const SettingsState()) {
    on<LoadSettings>(_onLoad);
    on<SetBoolSetting>(_onSetBool);
    on<SetTtyMode>(_onSetTty);
    on<SetCalendarType>(_onSetCalendar);
    on<UpdateQuickReply>(_onUpdateReply);
  }

  String _boolKey(BoolSetting k) => '$_prefix${k.name}';

  Future<void> _onLoad(LoadSettings event, Emitter<SettingsState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    const defaults = SettingsState();

    bool b(BoolSetting k) => prefs.getBool(_boolKey(k)) ?? defaults.boolFor(k);

    final ttyName = prefs.getString(_ttyKey);
    final tty = TtyMode.values.firstWhere(
      (m) => m.name == ttyName,
      orElse: () => TtyMode.off,
    );
    final calendarName = prefs.getString(_calendarKey);
    final calendar = CalendarType.values.firstWhere(
      (c) => c.name == calendarName,
      orElse: () => defaults.calendarType,
    );
    // Mirror into the static formatter so every date rendered from now on uses
    // the persisted calendar, not just the widgets that read SettingsState.
    DateFormatter.calendar = calendar;

    final replies =
        prefs.getStringList(_quickKey) ?? SettingsState.defaultQuickReplies;

    emit(
      SettingsState(
        showDialpadOnStart: b(BoolSetting.showDialpadOnStart),
        sortByLastName: b(BoolSetting.sortByLastName),
        nameFormatLastFirst: b(BoolSetting.nameFormatLastFirst),
        alsoVibrate: b(BoolSetting.alsoVibrate),
        keypadTones: b(BoolSetting.keypadTones),
        dialpadTones: b(BoolSetting.dialpadTones),
        hearingAids: b(BoolSetting.hearingAids),
        noiseReduction: b(BoolSetting.noiseReduction),
        callerIdSpam: b(BoolSetting.callerIdSpam),
        filterSpam: b(BoolSetting.filterSpam),
        ttyMode: tty,
        calendarType: calendar,
        quickReplies: replies,
      ),
    );
  }

  Future<void> _onSetBool(
    SetBoolSetting event,
    Emitter<SettingsState> emit,
  ) async {
    var next = state.withBool(event.key, event.value);
    // Spam filtering requires caller-ID to be on.
    if (event.key == BoolSetting.callerIdSpam && !event.value) {
      next = next.copyWith(filterSpam: false);
    }
    emit(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_boolKey(event.key), event.value);
    if (event.key == BoolSetting.callerIdSpam && !event.value) {
      await prefs.setBool(_boolKey(BoolSetting.filterSpam), false);
    }
  }

  Future<void> _onSetTty(SetTtyMode event, Emitter<SettingsState> emit) async {
    emit(state.copyWith(ttyMode: event.mode));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_ttyKey, event.mode.name);
  }

  Future<void> _onSetCalendar(
    SetCalendarType event,
    Emitter<SettingsState> emit,
  ) async {
    DateFormatter.calendar = event.calendarType;
    emit(state.copyWith(calendarType: event.calendarType));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_calendarKey, event.calendarType.name);
  }

  Future<void> _onUpdateReply(
    UpdateQuickReply event,
    Emitter<SettingsState> emit,
  ) async {
    if (event.index < 0 || event.index >= state.quickReplies.length) return;
    final updated = List<String>.from(state.quickReplies);
    updated[event.index] = event.text;
    emit(state.copyWith(quickReplies: updated));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_quickKey, updated);
  }
}
