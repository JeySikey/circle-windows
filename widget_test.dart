import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
void main() {
  testWidgets('Material theme basic smoke', (tester) async {
    await tester.pumpWidget(const MaterialApp(home: Scaffold(body: Text('Circle'))));
    expect(find.text('Circle'), findsOneWidget);
  });
}
