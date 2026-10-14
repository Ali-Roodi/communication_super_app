import 'package:bloc_test/bloc_test.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';

/// «مسدود کردن تماس»: the prefix list and the native mirror of the rules.
/// The decision itself is `CallRules` in Kotlin (`CallRulesTest`).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const callChannel = MethodChannel('com.example.communication_super_app/call');

  late List<Map<Object?, Object?>> mirrored;

  setUp(() {
    mirrored = [];
    SharedPreferences.setMockInitialValues({});
    messenger.setMockMethodCallHandler(callChannel, (call) async {
      if (call.method == 'setCallBlockRules') {
        mirrored.add(Map<Object?, Object?>.from(call.arguments as Map));
      }
      return null;
    });
  });

  tearDown(() => messenger.setMockMethodCallHandler(callChannel, null));

  group('CallBlockPrefixes.normalize (mirrors CallRules.normalizePrefix)', () {
    test('every spelling of a prefix becomes the national form', () {
      for (final input in [
        '0942',
        '+98942',
        '98942',
        '0098942',
        '942',
        '۰۹۴۲',
        '٠٩٤٢',
        ' 09 42 ',
      ]) {
        expect(CallBlockPrefixes.normalize(input), '0942', reason: input);
      }
      expect(CallBlockPrefixes.normalize('021 91'), '02191');
    });

    test('too short or foreign is refused', () {
      for (final input in ['', '09', '091', '+1415', 'abc']) {
        expect(CallBlockPrefixes.normalize(input), isNull, reason: input);
      }
    });

    test('add normalises and never duplicates', () {
      expect(CallBlockPrefixes.add(['0942'], '+98942'), ['0942']);
      expect(CallBlockPrefixes.add(['0942'], '0990'), ['0942', '0990']);
      expect(CallBlockPrefixes.add(['0942'], '09'), isNull);
    });
  });

  test('the default list is 0942', () {
    expect(const SettingsState().adPrefixes, ['0942']);
    expect(const SettingsState().blockAdvertising, isFalse);
    expect(const SettingsState().blockNonContacts, isFalse);
    expect(const SettingsState().blockInternational, isFalse);
    expect(const SettingsState().hideNotificationContent, isTrue);
  });

  blocTest<SettingsBloc, SettingsState>(
    'LoadSettings mirrors the rules natively, defaults included',
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const LoadSettings()),
    expect: () => [const SettingsState()],
    verify: (_) {
      expect(mirrored, isNotEmpty);
      expect(mirrored.last, {
        'nonContacts': false,
        'international': false,
        'advertising': false,
        'adPrefixes': ['0942'],
      });
    },
  );

  blocTest<SettingsBloc, SettingsState>(
    'a rule switch is persisted and mirrored as a whole set',
    build: SettingsBloc.new,
    act: (bloc) =>
        bloc.add(const SetBoolSetting(BoolSetting.blockNonContacts, true)),
    expect: () => [const SettingsState(blockNonContacts: true)],
    verify: (_) async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getBool('set_blockNonContacts'), isTrue);
      expect(mirrored.single['nonContacts'], isTrue);
      expect(mirrored.single['adPrefixes'], ['0942']);
    },
  );

  blocTest<SettingsBloc, SettingsState>(
    'a switch that is not a call rule does not touch the mirror',
    build: SettingsBloc.new,
    act: (bloc) =>
        bloc.add(const SetBoolSetting(BoolSetting.dialpadHaptics, false)),
    expect: () => [const SettingsState(dialpadHaptics: false)],
    verify: (_) => expect(mirrored, isEmpty),
  );

  blocTest<SettingsBloc, SettingsState>(
    'SetAdPrefixes normalises, drops junk and duplicates, persists, mirrors',
    build: SettingsBloc.new,
    act: (bloc) =>
        bloc.add(const SetAdPrefixes(['0942', '+98942', '۰۹۹۰', '09', 'x'])),
    expect: () => [
      const SettingsState(adPrefixes: ['0942', '0990']),
    ],
    verify: (_) async {
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getStringList('set_ad_prefixes'), ['0942', '0990']);
      expect(mirrored.single['adPrefixes'], ['0942', '0990']);
    },
  );

  blocTest<SettingsBloc, SettingsState>(
    'an emptied list stays empty (it does not come back as the default)',
    setUp: () =>
        SharedPreferences.setMockInitialValues({'set_ad_prefixes': <String>[]}),
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const LoadSettings()),
    expect: () => [const SettingsState(adPrefixes: [])],
  );

  blocTest<SettingsBloc, SettingsState>(
    'a stored list is re-normalised on load',
    setUp: () => SharedPreferences.setMockInitialValues({
      'set_ad_prefixes': <String>['+98942', '0942', '1'],
    }),
    build: SettingsBloc.new,
    act: (bloc) => bloc.add(const LoadSettings()),
    expect: () => [
      const SettingsState(adPrefixes: ['0942']),
    ],
  );
}
