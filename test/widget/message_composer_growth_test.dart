import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:communication_super_app/features/messages/screens/widgets/message_composer.dart';

/// The composer's field must grow with the message and then stop, exactly like
/// Google Messages: ten-ish lines, after which the text scrolls inside it.
void main() {
  late TextEditingController controller;

  setUp(() => controller = TextEditingController());
  tearDown(() => controller.dispose());

  Future<double> fieldHeight(WidgetTester tester, String text) async {
    controller.text = text;
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              const Spacer(),
              MessageComposer(
                controller: controller,
                showStickers: false,
                onToggleStickers: () {},
                onAttach: () {},
                onSend: () {},
                onStickerSelected: (_) {},
              ),
            ],
          ),
        ),
      ),
    );
    await tester.pump();
    return tester.getSize(find.byType(TextField)).height;
  }

  String lines(int count) =>
      List.generate(count, (i) => 'خط شماره $i').join('\n');

  testWidgets('grows line by line as the message gets longer', (tester) async {
    final one = await fieldHeight(tester, 'سلام');
    final three = await fieldHeight(tester, lines(3));
    final six = await fieldHeight(tester, lines(6));

    expect(three, greaterThan(one));
    expect(six, greaterThan(three));
  });

  testWidgets('stops growing at the cap and scrolls instead', (tester) async {
    final ten = await fieldHeight(tester, lines(10));
    final forty = await fieldHeight(tester, lines(40));

    expect(forty, ten);
  });

  testWidgets('a one-line message keeps the field one line tall', (
    tester,
  ) async {
    final empty = await fieldHeight(tester, '');
    final one = await fieldHeight(tester, 'سلام');
    final two = await fieldHeight(tester, lines(2));

    expect(one, empty);
    expect(two, greaterThan(one));
  });
}
