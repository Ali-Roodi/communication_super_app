import 'package:communication_super_app/core/widgets/infinite_scroll.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  Widget list(int count, {required bool hasMore, required VoidCallback more}) =>
      MaterialApp(
        home: Scaffold(
          body: InfiniteScroll(
            hasMore: hasMore,
            onLoadMore: more,
            child: ListView.builder(
              itemCount: count,
              itemBuilder: (_, i) => SizedBox(height: 80, child: Text('$i')),
            ),
          ),
        ),
      );

  testWidgets('a first page too short to scroll still asks for the next', (
    tester,
  ) async {
    var asked = 0;
    await tester.pumpWidget(list(3, hasMore: true, more: () => asked++));
    await tester.pump();
    expect(asked, greaterThan(0));
  });

  testWidgets('a long page asks only near its end', (tester) async {
    var asked = 0;
    await tester.pumpWidget(list(100, hasMore: true, more: () => asked++));
    await tester.pump();
    expect(asked, 0);
    await tester.drag(find.byType(ListView), const Offset(0, -300));
    await tester.pump();
    expect(asked, 0);
    await tester.fling(find.byType(ListView), const Offset(0, -20000), 5000);
    await tester.pumpAndSettle();
    expect(asked, greaterThan(0));
  });

  testWidgets('nothing is asked once there is no more', (tester) async {
    var asked = 0;
    await tester.pumpWidget(list(3, hasMore: false, more: () => asked++));
    await tester.pump();
    expect(asked, 0);
  });
}
