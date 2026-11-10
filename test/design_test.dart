import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/design.dart';

void main() {
  test('Circle 5.2.3 palette remains consistent', () {
    expect(circleBackground, const Color(0xFF101113));
    expect(circlePanel, const Color(0xFF191B1F));
    expect(circleGold, const Color(0xFFC6A15B));
    expect(circleGoldBright, const Color(0xFFE2C17C));
  });
  testWidgets('Native theme has branded surface and buttons', (tester) async {
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body: Center(child: CircleSurface(child: const Text('Твой круг. Твои люди.'))))));
    expect(find.text('Твой круг. Твои люди.'), findsOneWidget);
    expect(Theme.of(tester.element(find.text('Твой круг. Твои люди.'))).scaffoldBackgroundColor, circleBackground);
  });
  test('Russian display date is predictable', () {
    expect(circleDate('2025-11-10 13:20:00'), '10.11.2025');
  });
}
