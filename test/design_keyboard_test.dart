import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/design.dart';

void main() {
  for (final light in [false, true]) {
    testWidgets(
        'Keyboard navigation has visible focus in ${light ? 'light' : 'dark'} theme',
        (tester) async {
      final semantics = tester.ensureSemantics();
      try {
        var navigationPresses = 0;
        var actionPresses = 0;
        final theme = circleTheme(light: light);
        const navigationKey = ValueKey('navigation');
        const actionKey = ValueKey('action');
        await tester.pumpWidget(MaterialApp(
            theme: theme,
            home: Scaffold(
                body: Row(children: [
              SizedBox(
                  width: 246,
                  child: CircleNavItem(
                      key: navigationKey,
                      icon: Icons.home,
                      title: 'Главная',
                      active: true,
                      onTap: () => navigationPresses++)),
              const CircleIconAction(
                  icon: Icons.lock, tooltip: 'Недоступно', onPressed: null),
              CircleIconAction(
                  key: actionKey,
                  icon: Icons.search,
                  tooltip: 'Поиск',
                  onPressed: () => actionPresses++),
            ]))));

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final navigation =
            tester.getSemantics(find.bySemanticsLabel('Главная'));
        expect(navigation.getSemanticsData().flagsCollection.isFocused,
            ui.Tristate.isTrue);
        final navigationDecoration = tester
            .widget<AnimatedContainer>(find
                .descendant(
                    of: find.byKey(navigationKey),
                    matching: find.byType(AnimatedContainer))
                .first)
            .decoration! as BoxDecoration;
        expect((navigationDecoration.border! as Border).top.color,
            theme.colorScheme.primary);
        expect((navigationDecoration.border! as Border).top.width, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pumpAndSettle();
        expect(navigationPresses, 1);

        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
        await tester.pumpAndSettle();
        final action = tester.getSemantics(find.bySemanticsLabel('Поиск'));
        expect(action.getSemanticsData().flagsCollection.isFocused,
            ui.Tristate.isTrue);
        final actionDecoration = tester
            .widget<AnimatedContainer>(find
                .descendant(
                    of: find.byKey(actionKey),
                    matching: find.byType(AnimatedContainer))
                .first)
            .decoration! as BoxDecoration;
        expect((actionDecoration.border! as Border).top.color,
            theme.colorScheme.primary);
        expect((actionDecoration.border! as Border).top.width, 2);
        await tester.sendKeyEvent(LogicalKeyboardKey.space);
        await tester.pumpAndSettle();
        expect(actionPresses, 1);

        final disabled =
            tester.getSemantics(find.bySemanticsLabel('Недоступно'));
        expect(disabled.getSemanticsData().flagsCollection.isEnabled,
            isNot(ui.Tristate.none));
        expect(disabled.getSemanticsData().flagsCollection.isEnabled,
            ui.Tristate.isFalse);
        expect(disabled.getSemanticsData().flagsCollection.isFocused,
            isNot(ui.Tristate.isTrue));
        expect(disabled.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            isFalse);
        expect(tester.takeException(), isNull);
      } finally {
        semantics.dispose();
      }
    });
  }

  testWidgets(
      'Compact navigation preserves its selected accessible name while resizing',
      (tester) async {
    final semantics = tester.ensureSemantics();
    try {
      var presses = 0;
      for (final width in [78.0, 122.0, 180.0, 246.0]) {
        await tester.pumpWidget(MaterialApp(
            theme: circleTheme(),
            home: Scaffold(
                body: SizedBox(
                    width: width,
                    child: CircleNavItem(
                        icon: Icons.home,
                        title: 'Главная',
                        active: true,
                        compact: width == 78,
                        onTap: () => presses++)))));
        await tester.pumpAndSettle();
        expect(find.bySemanticsLabel('Главная'), findsOneWidget);
        final navigation =
            tester.getSemantics(find.bySemanticsLabel('Главная'));
        expect(navigation.getSemanticsData().flagsCollection.isSelected,
            ui.Tristate.isTrue);
        expect(navigation.getSemanticsData().flagsCollection.isButton, isTrue);
        expect(navigation.getSemanticsData().hasAction(ui.SemanticsAction.tap),
            isTrue);
        expect(tester.takeException(), isNull);
      }
      await tester.tap(find.byType(CircleNavItem));
      await tester.pumpAndSettle();
      expect(presses, 1);
    } finally {
      semantics.dispose();
    }
  });
}
