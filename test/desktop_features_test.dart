import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/desktop_features.dart';

void main() {
  testWidgets('Circle community creation stays native at desktop and compact widths', (tester) async {
    final api = CircleApi('https://example.org');
    addTearDown(api.dispose);
    for (final width in [1100.0, 560.0]) {
      await tester.binding.setSurfaceSize(Size(width, 820));
      await tester.pumpWidget(MaterialApp(theme:circleTheme(), home: DesktopCreateCommunity(api)));
      expect(find.text('Создай свой круг'), findsOneWidget);
      expect(find.text('Создать сообщество'), findsOneWidget);
      expect(find.byType(TextField), findsNWidgets(2));
    }
    await tester.binding.setSurfaceSize(null);
  });
  testWidgets('Responsive heading wraps actions below text on narrow window', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 680));
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(body:
      Center(child: SizedBox(width: 350, child: CircleSection(
        title:'Роли и права',subtitle:'Проверяются сервером',
        trailing: OutlinedButton(onPressed:(){}, child:const Text('Добавить роль'))))))));
    expect(find.text('Роли и права'), findsOneWidget);
    expect(find.text('Добавить роль'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}
