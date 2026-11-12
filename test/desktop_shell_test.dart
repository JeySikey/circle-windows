import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/main.dart';

const _captureUi = bool.fromEnvironment('CIRCLE_CAPTURE_UI');
const _previewDirectory = String.fromEnvironment('CIRCLE_PREVIEW_DIRECTORY',
    defaultValue: '../preview');
const _demoUser = <String, dynamic>{
  'id': 1,
  'username': 'circle_demo',
  'display_name': 'Алексей',
  'platform_role': 'USER',
};
const _demoPeer = <String, dynamic>{
  'id': 2,
  'username': 'alice',
  'display_name': 'Алиса',
};

/// Only local demo fixtures are used. Every HTTP client created by CircleApp
/// lives in this zone; these tests never contact a real Circle deployment.
class _ShellFixture {
  final requests = <String>[];
  final unexpected = <String>[];

  http.Client client() => MockClient((request) async {
        expect(request.url.host, 'circle.test');
        expect(request.headers['Authorization'], 'Bearer fixture-session');
        final route = request.url.queryParameters['route']!;
        requests.add(route);
        final Map<String, dynamic> payload;
        switch (route) {
          case 'me':
            payload = {'user': _demoUser};
          case 'desktop-presence':
            payload = {'status': 'ONLINE'};
          case 'desktop-presence-ping':
            payload = {};
          // Circle 0.11 initializes native notifications after session restore.
          // These are expected authenticated requests, not unknown API calls.
          case 'notification-settings':
            payload = {
              'settings': <String, bool>{
                'messages': true,
                'friends': true,
                'communities': true,
                'posts': true,
                'calls': true,
              },
            };
          case 'notifications':
            payload = {'items': <dynamic>[], 'unread': 0};
          case 'mobile-call-poll':
            payload = {'call': null};
          case 'feed':
            payload = {
              'items': [
                {
                  'id': 10,
                  'author': _demoPeer,
                  'title': 'Вечер в своём круге',
                  'body': 'Собираемся на игру. Кто сегодня с нами?',
                  'created_at': '2026-11-12 12:00:00',
                  'stats': {'likes': 12, 'comments': 3, 'reposts': 1}
                },
              ]
            };
          case 'stories':
          case 'friends':
          case 'friend-requests':
          case 'communities':
          case 'profile-posts':
            payload = {'items': <dynamic>[]};
          case 'profile':
            payload = {
              'user': _demoUser,
              'counts': {'friends': 8, 'posts': 2, 'communities': 1}
            };
          case 'desktop-conversations':
            payload = {
              'items': [
                {
                  'id': 11,
                  'peer': _demoPeer,
                  'last_message': 'Во сколько собираемся?'
                },
                {
                  'id': 22,
                  'peer': {
                    'id': 3,
                    'username': 'boris',
                    'display_name': 'Борис'
                  },
                  'last_message': 'До вечера!'
                },
                {
                  'id': 33,
                  'peer': {
                    'id': 0,
                    'username': 'saved',
                    'display_name': 'Избранное'
                  },
                  'saved': true,
                  'last_message': 'Мои заметки'
                },
              ]
            };
          case 'messages':
            payload = {
              'items': [
                {
                  'id': 101,
                  'user_id': 2,
                  'body': 'Привет! Во сколько собираемся?',
                  'created_at': '2026-11-12 18:20:00',
                  'attachments': <dynamic>[]
                },
                {
                  'id': 102,
                  'user_id': 1,
                  'body': 'Давай в восемь. Позову остальных.',
                  'created_at': '2026-11-12 18:21:00',
                  'attachments': <dynamic>[]
                },
                {
                  'id': 103,
                  'user_id': 2,
                  'body': 'Отлично, буду на связи.',
                  'created_at': '2026-11-12 18:22:00',
                  'attachments': <dynamic>[]
                },
              ]
            };
          default:
            unexpected.add(route);
            payload = {'items': <dynamic>[]};
        }
        return http.Response(jsonEncode({'ok': true, ...payload}), 200,
            headers: {'content-type': 'application/json; charset=utf-8'});
      });
}

Finder _nav(String title) => find.byWidgetPredicate(
    (widget) => widget is CircleNavItem && widget.title == title);

Future<void> _shortcut(WidgetTester tester, LogicalKeyboardKey key) async {
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(key);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
}

void _window(WidgetTester tester, Size size) {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = size;
}

void _resetWindow(WidgetTester tester) {
  tester.view.resetPhysicalSize();
  tester.view.resetDevicePixelRatio();
}

Future<void> _sidebarTop(WidgetTester tester) async {
  final list = find.byKey(const PageStorageKey('workspace-navigation'));
  expect(list, findsOneWidget);
  final scrollable =
      find.descendant(of: list, matching: find.byType(Scrollable));
  tester.state<ScrollableState>(scrollable).position.jumpTo(0);
  await tester.pumpAndSettle();
}

void _expectFooterVisible(WidgetTester tester, Size size) {
  final footer = find.byTooltip('Мой профиль');
  expect(footer, findsOneWidget);
  final rect = tester.getRect(footer);
  expect(rect.top, greaterThanOrEqualTo(0));
  expect(rect.bottom, lessThanOrEqualTo(size.height));
  expect(rect.left, greaterThanOrEqualTo(0));
  expect(rect.right, lessThanOrEqualTo(size.width));
}

Future<void> _disposeShell(WidgetTester tester) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // The optional startup update check is scheduled after the first frame.
  // Dispose before its delay elapses, then drain that harmless callback.
  await tester.pump(const Duration(seconds: 4));
}

Future<void> _capture(
    WidgetTester tester, GlobalKey boundary, String name) async {
  if (!_captureUi) return;
  await tester.runAsync(() async {
    final image = await (boundary.currentContext!.findRenderObject()
            as RenderRepaintBoundary)
        .toImage(pixelRatio: 1);
    try {
      final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
      final directory = Directory(_previewDirectory);
      await directory.create(recursive: true);
      await File('${directory.path}/$name.png')
          .writeAsBytes(bytes!.buffer.asUint8List());
    } finally {
      image.dispose();
    }
  });
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() async {
    if (!_captureUi) return;
    final icons = FontLoader('MaterialIcons')
      ..addFont(rootBundle.load('fonts/MaterialIcons-Regular.otf'));
    await icons.load();
    // Optional local preview only; normal Windows CI never needs this font.
    final font = File('/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf');
    if (await font.exists()) {
      final loader = FontLoader('Segoe UI')
        ..addFont(font.readAsBytes().then(ByteData.sublistView));
      await loader.load();
    }
  });
  setUp(() => FlutterSecureStorage.setMockInitialValues({
        'circle_server': 'https://circle.test',
        'circle_token': 'fixture-session',
      }));

  testWidgets(
      'Real desktop shell keeps navigation across sections and shortcuts',
      (tester) async {
    final fixture = _ShellFixture();
    addTearDown(() => _resetWindow(tester));
    await http.runWithClient(() async {
      const size = Size(1390, 870);
      _window(tester, size);
      await tester.pumpWidget(const CircleApp());
      await tester.pumpAndSettle();
      expect(find.byType(FeedScreen), findsOneWidget);
      expect(fixture.requests, containsAll(['me', 'feed', 'stories']));
      _expectFooterVisible(tester, size);

      await tester.ensureVisible(_nav('Сообщества'));
      await tester.tap(_nav('Сообщества'));
      await tester.pumpAndSettle();
      expect(find.byType(CommunitiesScreen), findsOneWidget);
      expect(find.byKey(const PageStorageKey('workspace-navigation')),
          findsOneWidget);
      expect(tester.widget<CircleNavItem>(_nav('Сообщества')).active, isTrue);
      await _sidebarTop(tester);
      expect(find.byKey(const ValueKey('main-nav-0')), findsOneWidget);
      _expectFooterVisible(tester, size);

      await _shortcut(tester, LogicalKeyboardKey.digit3);
      expect(find.byType(CommunitiesScreen), findsNothing);
      expect(find.byType(MessengerScreen), findsOneWidget);
      expect(find.byType(CircleConversationTile), findsNWidgets(3));
      expect(tester.widget<CircleNavItem>(_nav('Мессенджер')).active, isTrue);

      await _shortcut(tester, LogicalKeyboardKey.digit1);
      expect(find.byType(FeedScreen), findsOneWidget);
      expect(tester.widget<CircleNavItem>(_nav('Главная')).active, isTrue);
      expect(fixture.requests.where((route) => route == 'feed'), hasLength(1));

      expect(find.byTooltip('Свернуть меню'), findsOneWidget,
          reason:
              'Available tooltips: ${tester.widgetList<Tooltip>(find.byType(Tooltip)).map((item) => item.message).join(', ')}');
      await tester.tap(find.byTooltip('Свернуть меню'));
      await tester.pumpAndSettle();
      expect(tester.widget<CircleNavItem>(_nav('Главная')).compact, isTrue);
      _expectFooterVisible(tester, size);
      await tester.tap(find.byTooltip('Развернуть меню'));
      await tester.pumpAndSettle();
      expect(tester.widget<CircleNavItem>(_nav('Главная')).compact, isFalse);
      expect(fixture.unexpected, isEmpty);
      expect(tester.takeException(), isNull);
      await _disposeShell(tester);
    }, fixture.client);
  });

  testWidgets('Real shell and active chat fit small windows and larger text',
      (tester) async {
    final fixture = _ShellFixture();
    final boundary = GlobalKey();
    addTearDown(() => _resetWindow(tester));
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    await http.runWithClient(() async {
      _window(tester, const Size(1390, 870));
      await tester
          .pumpWidget(RepaintBoundary(key: boundary, child: const CircleApp()));
      await tester.pumpAndSettle();
      if (_captureUi) {
        await tester.runAsync(() => precacheImage(
            const AssetImage('assets/circle-mark.png'),
            tester.element(find.byType(CircleApp))));
        await tester.pumpAndSettle();
      }
      await _shortcut(tester, LogicalKeyboardKey.digit3);
      await tester.tap(find.text('Алиса'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'Скоро буду!');
      final chatState = tester.state(find.byType(MessagesScreen));

      for (final layout in [
        (const Size(1390, 870), 1.0, 'windows-wide-demo'),
        (const Size(1390, 870), 1.5, 'windows-wide-large-text-demo'),
        (const Size(760, 550), 1.0, 'windows-compact-demo'),
        (const Size(760, 550), 1.5, 'windows-compact-large-text-demo'),
      ]) {
        tester.platformDispatcher.textScaleFactorTestValue = layout.$2;
        _window(tester, layout.$1);
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull,
            reason: 'Window ${layout.$1}, text scale ${layout.$2}');
        _expectFooterVisible(tester, layout.$1);
        expect(tester.state(find.byType(MessagesScreen)), same(chatState));
        expect(
            tester.widget<TextField>(find.byType(TextField)).controller!.text,
            'Скоро буду!');
        expect(find.byTooltip('Отправить сообщение'), findsOneWidget);
        await _capture(tester, boundary, layout.$3);
      }
      expect(fixture.unexpected, isEmpty);
      await _disposeShell(tester);
    }, fixture.client);
  });
}
