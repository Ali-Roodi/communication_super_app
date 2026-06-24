import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

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
        bloc.add(const SetBoolSetting(BoolSetting.sortByLastName, true)),
    expect: () => [const SettingsState(sortByLastName: true)],
  );

  blocTest<SettingsBloc, SettingsState>(
    'turning OFF caller-ID spam also turns OFF spam filtering (dependency)',
    build: SettingsBloc.new,
    // Start with both on, then turn caller-ID off.
    seed: () => const SettingsState(callerIdSpam: true, filterSpam: true),
    act: (bloc) =>
        bloc.add(const SetBoolSetting(BoolSetting.callerIdSpam, false)),
    expect: () => [const SettingsState(callerIdSpam: false, filterSpam: false)],
  );

  blocTest<SettingsBloc, SettingsState>(
    'UpdateQuickReply with an out-of-range index is a no-op',
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const UpdateQuickReply(99, 'x')),
    expect: () => const <SettingsState>[],
  );

  blocTest<SettingsBloc, SettingsState>(
    'UpdateQuickReply replaces the reply at the given index',
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const UpdateQuickReply(0, 'سلام')),
    expect: () => [
      isA<SettingsState>().having(
        (s) => s.quickReplies.first,
        'first quick reply',
        'سلام',
      ),
    ],
  );
}
