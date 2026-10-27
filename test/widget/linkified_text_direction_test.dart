import 'package:communication_super_app/features/messages/screens/widgets/linkified_text.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(String text, {ValueChanged<String>? onSelection}) => MaterialApp(
  home: Directionality(
    textDirection: TextDirection.rtl,
    child: Scaffold(
      body: Center(
        child: SelectionArea(
          onSelectionChanged: (c) => onSelection?.call(c?.plainText ?? ''),
          child: LinkifiedText(text: text),
        ),
      ),
    ),
  ),
);

List<RichText> _paragraphs(WidgetTester tester) =>
    tester.widgetList<RichText>(find.byType(RichText)).toList();

void main() {
  testWidgets('a Latin message is one left-to-right paragraph', (tester) async {
    await tester.pumpWidget(_host('Your code is 1234'));
    final p = _paragraphs(tester);
    expect(p, hasLength(1));
    expect(p.single.textDirection, TextDirection.ltr);
  });

  testWidgets('a Persian message is one right-to-left paragraph', (
    tester,
  ) async {
    await tester.pumpWidget(_host('سلام\nخوبی؟'));
    final p = _paragraphs(tester);
    expect(p, hasLength(1));
    expect(p.single.textDirection, TextDirection.rtl);
  });

  testWidgets('a Latin line inside Persian gets its own direction', (
    tester,
  ) async {
    await tester.pumpWidget(_host('کد شما:\nHello World\nممنون'));
    final p = _paragraphs(tester);
    expect(p.map((r) => r.textDirection), [
      TextDirection.rtl,
      TextDirection.ltr,
      TextDirection.rtl,
    ]);
    // Same width, so each one's start edge is a side of the bubble.
    final widths = {
      for (final f in find.byType(RichText).evaluate())
        tester.getSize(find.byWidget(f.widget)).width,
    };
    expect(widths, hasLength(1));
  });

  testWidgets('selecting across paragraphs copies the newlines', (
    tester,
  ) async {
    var selected = '';
    const text = 'کد شما:\n\nHello World\nممنون';
    await tester.pumpWidget(_host(text, onSelection: (s) => selected = s));
    // The paragraphs register with their container after the first frame.
    await tester.pump();
    final region = tester.state<SelectableRegionState>(
      find.byType(SelectableRegion),
    );
    region.selectAll(SelectionChangedCause.toolbar);
    await tester.pump();
    expect(selected, text);
  });
}
