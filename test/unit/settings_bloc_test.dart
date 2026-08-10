import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/core/utils/contact_name_style.dart';
import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
    ContactNameStyle.lastNameFirst = false;
    ContactNameStyle.sortByLastName = false;
  });

  blocTest<SettingsBloc, SettingsState>(
    'LoadSettings emits defaults when nothing is persisted',
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const LoadSettings()),
    expect: () => [const SettingsState()],
  );

  blocTest<SettingsBloc, SettingsState>(
    'toggling a bool setting emits the updated state',
    build: SettingsBloc.new,
    act: (bloc) =>
        bloc.add(const SetBoolSetting(BoolSetting.dialpadHaptics, false)),
    expect: () => [const SettingsState(dialpadHaptics: false)],
  );

  // The contacts list is rendered from ContactRepository's cache, which bakes
  // the format and the ordering in — the statics have to be updated by the
  // BLoC, or the setting changes nothing until the next cold start.
  blocTest<SettingsBloc, SettingsState>(
    'the contact name style is mirrored onto ContactNameStyle',
    build: SettingsBloc.new,
    act: (bloc) => bloc
      ..add(const SetBoolSetting(BoolSetting.nameFormatLastFirst, true))
      ..add(const SetBoolSetting(BoolSetting.sortByLastName, true)),
    expect: () => [
      const SettingsState(nameFormatLastFirst: true),
      const SettingsState(nameFormatLastFirst: true, sortByLastName: true),
    ],
    verify: (_) {
      expect(ContactNameStyle.lastNameFirst, isTrue);
      expect(ContactNameStyle.sortByLastName, isTrue);
    },
  );

  // Preferences written by versions that had the accessibility page, the quick
  // replies and the caller-ID switches must not survive an upgrade.
  test('LoadSettings drops the retired preference keys', () async {
    SharedPreferences.setMockInitialValues({
      'set_tty_mode': 'full',
      'set_quick_replies': <String>['x'],
      'set_hearingAids': true,
      'set_callerIdSpam': true,
      'set_dialpadTones': false,
    });
    final bloc = SettingsBloc()..add(const LoadSettings());
    await bloc.stream.first;
    await bloc.close();

    final prefs = await SharedPreferences.getInstance();
    expect(prefs.containsKey('set_tty_mode'), isFalse);
    expect(prefs.containsKey('set_quick_replies'), isFalse);
    expect(prefs.containsKey('set_hearingAids'), isFalse);
    expect(prefs.containsKey('set_callerIdSpam'), isFalse);
    // …while a live one is left exactly as it was.
    expect(prefs.getBool('set_dialpadTones'), isFalse);
  });

  test('readShowDialpadOnStart reads the same key the BLoC writes', () async {
    SharedPreferences.setMockInitialValues({});
    expect(await SettingsBloc.readShowDialpadOnStart(), isFalse);

    final bloc = SettingsBloc()
      ..add(const SetBoolSetting(BoolSetting.showDialpadOnStart, true));
    await bloc.stream.first;
    await bloc.close();

    expect(await SettingsBloc.readShowDialpadOnStart(), isTrue);
  });
}
