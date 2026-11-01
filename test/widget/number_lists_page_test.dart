import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:communication_super_app/features/settings/bloc/settings_bloc.dart';
import 'package:communication_super_app/features/settings/bloc/settings_state.dart';
import 'package:communication_super_app/features/settings/screens/number_lists_page.dart';
import 'package:communication_super_app/features/settings/services/number_lists_bridge.dart';

class _RecordingBridge extends NumberListsBridge {
  final List<NumberLists> mirrored = [];
  @override
  Future<void> mirror(NumberLists lists) async => mirrored.add(lists);
}

void main() {
  late _RecordingBridge bridge;
  late SettingsBloc bloc;

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    bridge = _RecordingBridge();
    bloc = SettingsBloc(numberLists: bridge);
  });

  tearDown(() => bloc.close());

  Future<void> pump(WidgetTester tester) async {
    await tester.pumpWidget(
      BlocProvider.value(
        value: bloc,
        child: const MaterialApp(home: NumberListsPage()),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// The bloc handles the event a turn after the dialog closes.
  Future<void> settle(WidgetTester tester) async {
    await tester.pumpAndSettle();
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    await tester.pumpAndSettle();
  }

  testWidgets('a channel is switched to the white list', (tester) async {
    await pump(tester);
    expect(find.text('همه، به‌جز فهرست سیاه'), findsNWidgets(4));

    await tester.tap(find.text('تماس‌های ورودی'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('فقط فهرست سفید'));
    await settle(tester);

    expect(
      bloc.state.numberLists.modeOf(ListChannel.callIn),
      ListMode.whitelist,
    );
    expect(
      bloc.state.numberLists.modeOf(ListChannel.smsIn),
      ListMode.blacklist,
    );
    expect(find.text('فقط فهرست سفید'), findsOneWidget);
    expect(bridge.mirrored.last.modeOf(ListChannel.callIn), ListMode.whitelist);
  });

  testWidgets('an entry is added normalised, a bad one is refused', (
    tester,
  ) async {
    await pump(tester);

    // The black list's «افزودن» is the first of the two.
    await tester.tap(find.text('افزودن شماره یا الگو').first);
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '12');
    await tester.tap(find.text('افزودن'));
    await tester.pumpAndSettle();
    expect(find.textContaining('دست‌کم ۳ رقم'), findsOneWidget);

    await tester.enterText(find.byType(TextField), '+98 912 *');
    await tester.tap(find.text('افزودن'));
    await settle(tester);

    expect(bloc.state.numberLists.black, ['0912*']);
    expect(find.text('۰۹۱۲*'), findsOneWidget);

    await tester.tap(find.byTooltip('حذف'));
    await settle(tester);
    expect(bloc.state.numberLists.black, isEmpty);
  });
}
