import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/main.dart';

class _MessengerApi extends CircleApi {
  _MessengerApi() : super('https://example.test');
  Completer<Map<String, dynamic>>? pendingAlicePoll;
  Completer<Map<String, dynamic>>? pendingCall;
  Map<String, dynamic>? finishedCall;
  final Map<String, int> messageReads = {};

  @override
  Future<Map<String, dynamic>> call(
    String route, {
    Map<String, String> query = const {},
    Map<String, dynamic>? body,
    bool auth = true,
  }) async {
    if (route == 'desktop-conversations') {
      return {
        'ok': true,
        'items': [
          {
            'id': 11,
            'last_message': 'Первый диалог',
            'peer': {'id': 2, 'username': 'alice', 'display_name': 'Алиса'}
          },
          {
            'id': 22,
            'last_message': 'Второй диалог',
            'peer': {'id': 3, 'username': 'boris', 'display_name': 'Борис'}
          },
        ]
      };
    }
    if (route == 'messages') {
      final id = query['conversation_id']!;
      messageReads[id] = (messageReads[id] ?? 0) + 1;
      if (id == '11' && pendingAlicePoll != null) {
        return pendingAlicePoll!.future;
      }
      return _messages(id == '11' ? 'Сообщение Алисы' : 'Сообщение Бориса');
    }
    if (route == 'mobile-call-start' && pendingCall != null)
      return pendingCall!.future;
    if (route == 'mobile-call-finish') {
      finishedCall = body;
      return {'ok': true};
    }
    throw CircleError('Unexpected request $route');
  }
}

Map<String, dynamic> _messages(String body) => {
      'ok': true,
      'items': [
        {
          'id': 101,
          'user_id': 2,
          'body': body,
          'created_at': '2026-11-11 12:00:00',
          'attachments': <dynamic>[]
        },
      ]
    };

Widget _host(_MessengerApi api,
        {required double width, double textScale = 1}) =>
    MaterialApp(
        theme: circleTheme(),
        builder: (context, child) => MediaQuery(
            data: MediaQuery.of(context)
                .copyWith(textScaler: TextScaler.linear(textScale)),
            child: child!),
        home: Scaffold(
            body: Center(
                child: SizedBox(
                    width: width,
                    child: MessengerScreen(api, me: const {'id': 1})))));

void main() {
  testWidgets('Selected chat and draft survive resizing inside a wider window',
      (tester) async {
    final api = _MessengerApi();
    addTearDown(api.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(_host(api, width: 1200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Алиса'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Черновик для Алисы');
    final originalChat = tester.state(find.byType(MessagesScreen));

    await tester.pumpWidget(_host(api, width: 680));
    await tester.pumpAndSettle();
    expect(find.byType(CircleConversationTile), findsNothing);
    expect(find.byTooltip('К списку диалогов'), findsOneWidget);
    expect(find.text('Сообщение Алисы'), findsOneWidget);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Черновик для Алисы');
    expect(tester.state(find.byType(MessagesScreen)), same(originalChat));

    await tester.pumpWidget(_host(api, width: 1200));
    await tester.pumpAndSettle();
    expect(find.byType(CircleConversationTile), findsNWidgets(2));
    expect(tester.state(find.byType(MessagesScreen)), same(originalChat));
    expect(api.messageReads['11'], 1);

    await tester.pumpWidget(_host(api, width: 1000, textScale: 1.8));
    await tester.pumpAndSettle();
    expect(find.byType(CircleConversationTile), findsNothing);
    expect(tester.state(find.byType(MessagesScreen)), same(originalChat));
    await tester.tap(find.byTooltip('К списку диалогов'));
    await tester.pumpAndSettle();
    expect(find.byType(MessagesScreen), findsNothing);
    expect(find.byType(CircleConversationTile), findsNWidgets(2));
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Switching peers isolates drafts and ignores an old polling result',
      (tester) async {
    final api = _MessengerApi();
    addTearDown(api.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(_host(api, width: 1200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Алиса'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'Личный черновик Алисы');
    api.pendingAlicePoll = Completer<Map<String, dynamic>>();
    await tester.pump(const Duration(seconds: 7));
    expect(api.messageReads['11'], 2);

    await tester.tap(find.text('Борис'));
    await tester.pumpAndSettle();
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        isEmpty);
    await tester.enterText(find.byType(TextField), 'Черновик для Бориса');
    api.pendingAlicePoll!
        .complete(_messages('Поздний ответ из чужого диалога'));
    await tester.pumpAndSettle();
    expect(find.text('Сообщение Бориса'), findsOneWidget);
    expect(find.text('Поздний ответ из чужого диалога'), findsNothing);
    expect(tester.widget<TextField>(find.byType(TextField)).controller!.text,
        'Черновик для Бориса');
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Narrow chat with large text keeps composer and call actions usable',
      (tester) async {
    final api = _MessengerApi();
    addTearDown(api.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1000, 800));
    await tester.pumpWidget(_host(api, width: 480, textScale: 1.8));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Алиса'));
    await tester.pumpAndSettle();
    expect(find.byTooltip('Отправить сообщение'), findsOneWidget);
    expect(find.byTooltip('Прикрепить фото / видео'), findsOneWidget);
    expect(find.byTooltip('Записать голосовое сообщение'), findsOneWidget);
    await tester.enterText(
        find.byType(TextField), 'Сообщение с крупным текстом');
    await tester.tap(find.byTooltip('Действия с диалогом'));
    await tester.pumpAndSettle();
    expect(find.text('Голосовой звонок'), findsOneWidget);
    expect(find.text('Видеозвонок'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets(
      'Leaving a chat while a call starts cancels its server invitation',
      (tester) async {
    final api = _MessengerApi();
    addTearDown(api.dispose);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    await tester.pumpWidget(_host(api, width: 1200));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Алиса'));
    await tester.pumpAndSettle();
    api.pendingCall = Completer<Map<String, dynamic>>();
    await tester.tap(find.byTooltip('Голосовой звонок'));
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    api.pendingCall!.complete({'ok': true, 'call_id': 55});
    await tester.pumpAndSettle();
    expect(api.finishedCall, {'conversation_id': 11, 'call_id': 55});
    expect(tester.takeException(), isNull);
  });
}
