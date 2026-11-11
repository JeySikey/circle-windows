import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/social_presence.dart';
import 'package:circle_windows/desktop_discovery.dart';
import 'package:circle_windows/api.dart';

void main() {
  testWidgets('Branded CTA responds to click and keeps label readable', (tester) async {
    var presses = 0;
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body: Center(
      child: CircleAccentButton(label: 'Новая публикация', icon: Icons.add,
        onPressed: () => presses++)))));
    await tester.tap(find.text('Новая публикация'));
    await tester.pumpAndSettle();
    expect(presses, 1);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Nav item animates active state without overflow', (tester) async {
    await tester.binding.setSurfaceSize(const Size(360, 620));
    var count = 0;
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body:
      Column(children: [CircleNavItem(icon: Icons.home, title: 'Главная',
        compact: false, active: true, onTap: () => count++)]))));
    await tester.tap(find.text('Главная'));
    await tester.pumpAndSettle();
    expect(count, 1);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('Saved conversation renders without a network image', (tester) async {
    final api = CircleApi('https://example.com');
    addTearDown(api.dispose);
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body:
      CircleConversationTile(api: api, active: true, onTap: () {}, conversation: const {
        'saved': true, 'peer': {'id': 0, 'display_name': 'Избранное'},
        'last_message': 'Мои заметки',
      }))));
    expect(find.text('Избранное'), findsOneWidget);
    expect(find.text('Мои заметки'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
  testWidgets('Search screen is native and adapts its filter fields', (tester) async {
    final api = CircleApi('https://example.com');
    addTearDown(api.dispose);
    await tester.binding.setSurfaceSize(const Size(500, 840));
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body:
      CircleMessageSearchScreen(api: api,
        onOpenChannel: (_, __) {}, onOpenConversation: (_) {}))));
    expect(find.text('Найди важный разговор'), findsOneWidget);
    expect(find.text('Ключевые слова'), findsOneWidget);
    expect(find.text('Искать сообщения'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
  test('Presence labels are explicit and use the expected palette', () {
    expect(circlePresenceLabels['ONLINE'], 'В сети');
    expect(circlePresenceLabels['DND'], 'Не беспокоить');
    expect(circlePresenceColor('DND'), circleRed);
    expect(circlePresenceColor('OFFLINE'), circleMuted);
  });
}
