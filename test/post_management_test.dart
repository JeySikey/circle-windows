import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/main.dart';

class DemoApi extends CircleApi {
  DemoApi() : super('https://circle.example');
  final List<String> calls = [];
  @override
  Future<Map<String, dynamic>> call(String route, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    calls.add(route);
    return {'ok': true, 'reposted': true, 'total': 1};
  }
}

Map<String, dynamic> demoPost({required bool owned}) => {
  'id': 42, 'title': 'Публикация Circle', 'body': 'Проверка интерфейса',
  'created_at': '2026-11-10 12:00:00', 'comments_enabled': true,
  'can_edit': owned, 'is_pinned': false,
  'author': {'id': owned ? 1 : 2, 'username': 'member', 'display_name': 'Участник'},
  'stats': {'likes': 2, 'comments': 0, 'reposts': 0, 'reposted': false},
};

void main() {
  testWidgets('Own post shows edit controls and a repost action', (tester) async {
    final api = DemoApi();
    var reloaded = false;
    await tester.pumpWidget(MaterialApp(theme: circleTheme(),
      home: Scaffold(body: ListView(children: [PostCard(api, demoPost(owned: true), () => reloaded = true)]))));
    expect(find.text('Публикация Circle'), findsOneWidget);
    expect(find.byTooltip('Управление публикацией'), findsOneWidget);
    await tester.tap(find.text('0  Репост'));
    await tester.pump();
    expect(api.calls, contains('post-repost'));
    expect(reloaded, true);
    api.dispose();
  });

  testWidgets('Other members cannot see local edit controls', (tester) async {
    final api = DemoApi();
    await tester.pumpWidget(MaterialApp(theme: circleTheme(),
      home: Scaffold(body: PostCard(api, demoPost(owned: false), () {}))));
    expect(find.byTooltip('Управление публикацией'), findsNothing);
    api.dispose();
  });
}
