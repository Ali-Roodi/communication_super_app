import 'package:bloc_test/bloc_test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_event.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/services/number_lists_bridge.dart';

class _RecordingBridge extends NumberListsBridge {
  final List<NumberLists> mirrored = [];
  @override
  Future<void> mirror(NumberLists lists) async => mirrored.add(lists);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group(
    'NumberLists.normalizePattern (mirrors NumberListRules.normalizePattern)',
    () {
      // The same vectors as NumberListRulesTest.
      test('national form', () {
        const cases = {
          '09121234567': '09121234567',
          '+98 912 123 4567': '09121234567',
          '00989121234567': '09121234567',
          '989121234567': '09121234567',
          '9121234567': '09121234567',
          '۰۹۱۲-۱۲۳-۴۵۶۷': '09121234567',
          '0912*': '0912*',
          '+98912**': '0912*',
          '*۱۲۳۴': '*1234',
          '0912؟؟؟4567': '0912???4567',
          '021 *': '021*',
        };
        cases.forEach((input, expected) {
          expect(NumberLists.normalizePattern(input), expected, reason: input);
        });
      });

      test('unusable entries', () {
        for (final input in [
          '',
          '*',
          '09*',
          '0912abc',
          '+14155550100',
          '0014155550100',
          '2188776655',
          '110',
          '0912*1*2*3*4*5*6*7*8*9',
        ]) {
          expect(NumberLists.normalizePattern(input), isNull, reason: input);
        }
      });

      test('add normalises and drops duplicates', () {
        expect(NumberLists.add(const [], '+98912*'), ['0912*']);
        expect(NumberLists.add(const ['0912*'], '0912**'), ['0912*']);
        expect(NumberLists.add(const ['0912*'], '12'), isNull);
      });
    },
  );

  test('defaults restrict nothing', () {
    const lists = NumberLists();
    for (final c in ListChannel.values) {
      expect(lists.modeOf(c), ListMode.blacklist);
    }
    expect(lists.activeChannels, 0);
    expect(ListMode.of('anything'), ListMode.blacklist);
    // A channel left out equals one set to the default.
    expect(lists, lists.withMode(ListChannel.smsIn, ListMode.blacklist));
  });

  group('SettingsBloc', () {
    late _RecordingBridge bridge;
    setUp(() => bridge = _RecordingBridge());

    blocTest<SettingsBloc, SettingsState>(
      'stores and mirrors the lists, re-normalised',
      setUp: () => SharedPreferences.setMockInitialValues({}),
      build: () => SettingsBloc(numberLists: bridge),
      act: (bloc) => bloc.add(
        const SetNumberLists(
          NumberLists(
            modes: {ListChannel.callIn: ListMode.whitelist},
            black: ['+98912*', 'x'],
            white: ['09351112233'],
            contactsAllowed: true,
          ),
        ),
      ),
      expect: () => [
        const SettingsState(
          numberLists: NumberLists(
            modes: {ListChannel.callIn: ListMode.whitelist},
            black: ['0912*'],
            white: ['09351112233'],
            contactsAllowed: true,
          ),
        ),
      ],
      verify: (_) async {
        final prefs = await SharedPreferences.getInstance();
        expect(prefs.getString('set_list_mode_call_in'), 'whitelist');
        expect(prefs.getString('set_list_mode_sms_in'), 'blacklist');
        expect(prefs.getStringList('set_list_black'), ['0912*']);
        expect(prefs.getBool('set_list_contacts'), isTrue);
        expect(bridge.mirrored.single.black, ['0912*']);
        expect(
          bridge.mirrored.single.modeOf(ListChannel.callIn),
          ListMode.whitelist,
        );
      },
    );

    blocTest<SettingsBloc, SettingsState>(
      'loads what was stored and mirrors it on every load',
      setUp: () => SharedPreferences.setMockInitialValues({
        'set_list_mode_sms_out': 'nobody',
        'set_list_white': <String>['+98912*', 'junk', '0912*'],
      }),
      build: () => SettingsBloc(numberLists: bridge),
      act: (bloc) => bloc.add(const LoadSettings()),
      verify: (bloc) {
        final lists = bloc.state.numberLists;
        expect(lists.modeOf(ListChannel.smsOut), ListMode.nobody);
        expect(lists.modeOf(ListChannel.smsIn), ListMode.blacklist);
        expect(lists.white, ['0912*']);
        expect(lists.activeChannels, 1);
        expect(bridge.mirrored.single, lists);
      },
    );
  });
}
