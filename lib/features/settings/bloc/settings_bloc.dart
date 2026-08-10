import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:communication_super_app/core/utils/contact_name_style.dart';
import 'package:communication_super_app/core/utils/date_formatter.dart';
import 'package:communication_super_app/features/messages/services/sms_service.dart';
import 'settings_event.dart';
import 'settings_state.dart';

/// All app settings (except theme, which lives in ThemeBloc) persisted to
/// SharedPreferences. Keys are prefixed with `set_`.
class SettingsBloc extends Bloc<SettingsEvent, SettingsState> {
  static const _prefix = 'set_';
  static const _calendarKey = '${_prefix}calendar_type';

  /// Preferences written by versions that had settings this app no longer has
  /// (the accessibility page, the quick replies, the caller-ID switches, the
  /// keypad-sound/vibration pair). Dropped once on load so an upgraded install
  /// does not carry dead keys around for ever.
  static const List<String> _retiredKeys = [
    '${_prefix}tty_mode',
    '${_prefix}quick_replies',
    '${_prefix}hearingAids',
    '${_prefix}noiseReduction',
    '${_prefix}callerIdSpam',
    '${_prefix}filterSpam',
    '${_prefix}alsoVibrate',
    '${_prefix}keypadTones',
  ];

  SettingsBloc() : super(const SettingsState()) {
    on<LoadSettings>(_onLoad);
    on<SetBoolSetting>(_onSetBool);
    on<SetCalendarType>(_onSetCalendar);
  }

  static String _keyOf(BoolSetting k) => '$_prefix${k.name}';

  String _boolKey(BoolSetting k) => _keyOf(k);

  /// Reads «باز کردن صفحه‌کلید هنگام اجرای برنامه» straight from storage.
  ///
  /// `MainNavigation` needs the answer in its first post-frame callback, and
  /// `LoadSettings` is an async event that may not have landed yet — reading
  /// the state there would silently mean "off" on a slow cold start. Same key,
  /// so the two can't drift.
  static Future<bool> readShowDialpadOnStart() async {
    final prefs = await SharedPreferences.getInstance();
    return prefs.getBool(_keyOf(BoolSetting.showDialpadOnStart)) ?? false;
  }

  Future<void> _onLoad(LoadSettings event, Emitter<SettingsState> emit) async {
    final prefs = await SharedPreferences.getInstance();
    const defaults = SettingsState();

    bool b(BoolSetting k) => prefs.getBool(_boolKey(k)) ?? defaults.boolFor(k);

    final calendarName = prefs.getString(_calendarKey);
    final calendar = CalendarType.values.firstWhere(
      (c) => c.name == calendarName,
      orElse: () => defaults.calendarType,
    );
    // Mirror into the static formatter so every date rendered from now on uses
    // the persisted calendar, not just the widgets that read SettingsState.
    DateFormatter.calendar = calendar;
    // Same reason for delivery reports: sends originate in plain services and
    // in the native scheduled worker, neither of which can read this BLoC.
    SmsService.deliveryReports = b(BoolSetting.deliveryReports);
    // And for the contact name style, which is applied in ContactRepository as
    // each ContactModel is built. This runs before the first contacts read, so
    // no reload is triggered here (`apply` is a no-op at the defaults anyway).
    ContactNameStyle.apply(
      lastNameFirst: b(BoolSetting.nameFormatLastFirst),
      sortByLastName: b(BoolSetting.sortByLastName),
    );

    emit(
      SettingsState(
        showDialpadOnStart: b(BoolSetting.showDialpadOnStart),
        sortByLastName: b(BoolSetting.sortByLastName),
        nameFormatLastFirst: b(BoolSetting.nameFormatLastFirst),
        dialpadTones: b(BoolSetting.dialpadTones),
        dialpadHaptics: b(BoolSetting.dialpadHaptics),
        linkPreviews: b(BoolSetting.linkPreviews),
        swipeActions: b(BoolSetting.swipeActions),
        deliveryReports: b(BoolSetting.deliveryReports),
        calendarType: calendar,
      ),
    );

    for (final key in _retiredKeys) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
  }

  Future<void> _onSetBool(
    SetBoolSetting event,
    Emitter<SettingsState> emit,
  ) async {
    final next = state.withBool(event.key, event.value);
    if (event.key == BoolSetting.deliveryReports) {
      SmsService.deliveryReports = event.value;
    }
    // Applied before the state is emitted: `apply` invalidates the contact
    // cache and wakes ContactBloc, and a reload that started while the statics
    // still said the old thing would re-cache the old names.
    if (event.key == BoolSetting.nameFormatLastFirst ||
        event.key == BoolSetting.sortByLastName) {
      ContactNameStyle.apply(
        lastNameFirst: next.nameFormatLastFirst,
        sortByLastName: next.sortByLastName,
      );
    }
    emit(next);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_boolKey(event.key), event.value);
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
}
