import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/command_palette.dart';
import 'package:circle_windows/moderation_center.dart';
import 'package:circle_windows/platform_console.dart';

class _ModerationFixtureApi extends CircleApi {
  _ModerationFixtureApi() : super('https://example.test');
  Map<String, dynamic>? lastDecision;

  @override
  Future<Map<String, dynamic>> call(String route, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    if (route == 'desktop-moderation-inbox') return {
      'ok': true,
      'items': [
        {'id': 13, 'reporter': 'reporter', 'target': 'target',
          'target_user_id': 2, 'reason': 'Проверить сообщение',
          'status': 'OPEN', 'created_at': '2026-11-11 10:00:00'},
      ],
    };
    if (route == 'desktop-moderation-archive') return {
      'ok': true, 'page': 1, 'legacy': [], 'trust': [], 'history': {},
    };
    if (route == 'desktop-moderation-decide') {
      lastDecision = body;
      return {'ok': true};
    }
    throw CircleError('Unexpected request $route');
  }
}

class _PlatformFixtureApi extends CircleApi {
  _PlatformFixtureApi() : super('https://example.test');
  Map<String, dynamic>? lastFeature;
  @override
  Future<Map<String, dynamic>> call(String route, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    if (route == 'desktop-platform-console') return {
      'ok': true, 'features': [
        {'feature_key': 'stories', 'enabled': true,
          'description': 'Истории пользователей'},
      ], 'audit': [],
    };
    if (route == 'desktop-feature-toggle') {
      lastFeature = body;
      return {'ok': true};
    }
    throw CircleError('Unexpected request $route');
  }
}

void main() {
  testWidgets('Command palette filters locally and opens selected screen', (tester) async {
    await tester.binding.setSurfaceSize(const Size(420, 640));
    var selected = '';
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(
      body: Center(child: FilledButton(onPressed: () {
        showCircleCommandPalette(tester.element(find.byType(FilledButton)), [
          CircleCommand(title: 'Главная', subtitle: 'Лента', icon: Icons.home,
            onInvoke: () => selected = 'Главная'),
          CircleCommand(title: 'Архив решений', subtitle: 'История жалоб',
            icon: Icons.archive, onInvoke: () => selected = 'Архив'),
        ]);
      }, child: const Text('Поиск'))))));
    await tester.tap(find.text('Поиск'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'архив');
    await tester.pumpAndSettle();
    expect(find.text('Архив решений'), findsOneWidget);
    expect(find.text('Главная'), findsNothing);
    await tester.tap(find.text('Архив решений'));
    await tester.pumpAndSettle();
    expect(selected, 'Архив');
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Platform console requires confirmation before disabling a module',
      (tester) async {
    final api = _PlatformFixtureApi();
    addTearDown(api.dispose);
    await tester.binding.setSurfaceSize(const Size(850, 750));
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home:
      Scaffold(body: CirclePlatformConsole(api))));
    await tester.pumpAndSettle();
    expect(find.text('Истории пользователей'), findsOneWidget);
    await tester.tap(find.byType(Switch));
    await tester.pumpAndSettle();
    expect(find.text('Отключить модуль?'), findsOneWidget);
    await tester.tap(find.text('Отключить').last);
    await tester.pumpAndSettle();
    expect(api.lastFeature?['feature_key'], 'stories');
    expect(api.lastFeature?['enabled'], false);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });

  testWidgets('Moderation inbox makes explicit decision and preserves archive tab',
      (tester) async {
    final api = _ModerationFixtureApi();
    addTearDown(api.dispose);
    await tester.binding.setSurfaceSize(const Size(900, 780));
    await tester.pumpWidget(MaterialApp(theme: circleTheme(), home: Scaffold(
      body: CircleModerationCenter(api))));
    await tester.pumpAndSettle();
    expect(find.text('Жалобы пользователей'), findsOneWidget);
    expect(find.text('Проверить сообщение'), findsOneWidget);
    await tester.tap(find.text('Подтвердить'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Проверено модератором');
    await tester.tap(find.text('Подтвердить решение'));
    await tester.pumpAndSettle();
    expect(api.lastDecision?['report_id'], 13);
    expect(api.lastDecision?['status'], 'RESOLVED');
    expect(api.lastDecision?['note'], 'Проверено модератором');
    await tester.tap(find.text('Архив решений').first);
    await tester.pumpAndSettle();
    expect(find.text('Circle Trust'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.binding.setSurfaceSize(null);
  });
}
