import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/design.dart';
import 'package:circle_windows/desktop_workspace.dart';

void main() {
  testWidgets('Secondary routes keep the sidebar and main screen state',
      (tester) async {
    final workspace = GlobalKey<CircleWorkspaceState>();
    final routes = <String?>[];
    await tester.pumpWidget(MaterialApp(
        theme: circleTheme(),
        home: Scaffold(
          body: Row(children: [
            SizedBox(
                width: 90,
                child: TextButton(
                    onPressed: () => workspace.currentState!.showHome(),
                    child: const Text('Главная'))),
            Expanded(
                child: CircleWorkspace(
                    key: workspace,
                    onRouteChanged: routes.add,
                    home: const Center(
                        child: TextField(
                            decoration:
                                InputDecoration(labelText: 'Черновик'))))),
          ]),
        )));
    await tester.enterText(find.byType(TextField), 'Моя публикация');
    final homeState = tester.state(find.byType(TextField));

    final closed = workspace.currentState!.open(
        'Сообщества',
        Scaffold(
          appBar: AppBar(title: const Text('Сообщества')),
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () =>
                      Navigator.of(context).push<void>(MaterialPageRoute<void>(
                        settings: const RouteSettings(name: 'Канал'),
                        builder: (_) => Scaffold(
                            appBar: AppBar(title: const Text('Канал'))),
                      )),
                  child: const Text('Открыть канал'))),
        ));
    await tester.pumpAndSettle();
    expect(find.text('Главная'), findsOneWidget);
    expect(routes.last, 'Сообщества');
    await tester.tap(find.text('Открыть канал'));
    await tester.pumpAndSettle();
    expect(routes.last, 'Канал');
    await workspace.currentState!.back();
    await tester.pumpAndSettle();
    expect(routes.last, 'Сообщества');

    await tester.tap(find.text('Главная'));
    await tester.pumpAndSettle();
    await closed;
    expect(routes.last, isNull);
    expect(tester.state(find.byType(TextField)), same(homeState));
    expect(tester.widget<TextField>(find.byType(TextField)).controller, isNull);
    expect(find.text('Моя публикация'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Main content updates while a secondary route is open',
      (tester) async {
    final workspace = GlobalKey<CircleWorkspaceState>();
    var section = 'Лента';
    late StateSetter rebuild;
    await tester.pumpWidget(
        MaterialApp(home: StatefulBuilder(builder: (context, setState) {
      rebuild = setState;
      return CircleWorkspace(
          key: workspace, home: Center(child: Text(section)));
    })));
    workspace.currentState!
        .open('Безопасность', const Scaffold(body: Text('Устройства')));
    await tester.pumpAndSettle();
    rebuild(() => section = 'Друзья');
    await tester.pump();
    workspace.currentState!.showHome();
    await tester.pumpAndSettle();
    expect(find.text('Друзья'), findsOneWidget);
    expect(find.text('Лента'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Header adapts its actions to content width and text scaling',
      (tester) async {
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    for (final width in [682.0, 1144.0]) {
      for (final scale in [1.0, 1.5, 2.0]) {
        bool? compactHeader;
        await tester.pumpWidget(MaterialApp(
          theme: circleTheme(),
          builder: (context, child) => MediaQuery(
              data: MediaQuery.of(context)
                  .copyWith(textScaler: TextScaler.linear(scale)),
              child: child!),
          home: Scaffold(
            body: Align(
                alignment: Alignment.topLeft,
                child: SizedBox(
                    width: width,
                    child: CircleWorkspaceHeader(
                      title: 'Мессенджер',
                      subtitle: 'Личные разговоры и Избранное',
                      leading: IconButton(
                          onPressed: () {}, icon: const Icon(Icons.menu)),
                      actionsBuilder: (context, compact) {
                        compactHeader = compact;
                        return [
                          for (var i = 0; i < (compact ? 4 : 7); i++)
                            IconButton(
                                onPressed: () {},
                                icon: const Icon(Icons.circle_outlined)),
                        ];
                      },
                    ))),
          ),
        ));
        await tester.pump();
        expect(compactHeader, width < 900 * scale.clamp(1.0, 1.6));
        expect(find.text('Мессенджер'), findsOneWidget);
        expect(tester.takeException(), isNull,
            reason: 'width=$width scale=$scale');
      }
    }
  });

  testWidgets('Going home respects a guarded route until it permits leaving',
      (tester) async {
    final workspace = GlobalKey<CircleWorkspaceState>();
    var allowPop = false;
    var blockedPops = 0;
    var completedPops = 0;
    late StateSetter updateGuard;
    await tester.pumpWidget(MaterialApp(
        home: CircleWorkspace(
            key: workspace,
            home: const Scaffold(body: Text('Главная страница')))));
    final closed = workspace.currentState!.open('Звонок', StatefulBuilder(
      builder: (context, setState) {
        updateGuard = setState;
        return PopScope(
            canPop: allowPop,
            onPopInvokedWithResult: (didPop, _) {
              if (didPop) {
                completedPops++;
              } else {
                blockedPops++;
              }
            },
            child: const Scaffold(body: Text('Активный звонок')));
      },
    ));
    await tester.pumpAndSettle();

    expect(await workspace.currentState!.showHome(), isFalse);
    await tester.pumpAndSettle();
    expect(find.text('Активный звонок'), findsOneWidget);
    expect(find.text('Главная страница'), findsNothing);
    expect(blockedPops, 1);
    expect(completedPops, 0);

    updateGuard(() => allowPop = true);
    await tester.pump();
    expect(await workspace.currentState!.showHome(), isTrue);
    await tester.pumpAndSettle();
    await closed;
    expect(find.text('Главная страница'), findsOneWidget);
    expect(completedPops, 1);
    expect(tester.takeException(), isNull);
  });

  testWidgets('Unnamed descendants keep the selected section', (tester) async {
    final workspace = GlobalKey<CircleWorkspaceState>();
    final sections = <String?>[];
    await tester.pumpWidget(MaterialApp(
        home: CircleWorkspace(
            key: workspace,
            onRouteChanged: sections.add,
            home: const Scaffold(body: Text('Главная страница')))));
    final closed = workspace.currentState!.open(
        'Сообщества',
        Scaffold(
          body: Builder(
              builder: (context) => TextButton(
                  onPressed: () => Navigator.of(context).push<void>(
                      MaterialPageRoute<void>(
                          builder: (_) =>
                              const Scaffold(body: Text('Канал сообщества')))),
                  child: const Text('Открыть канал'))),
        ));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Открыть канал'));
    await tester.pumpAndSettle();
    expect(find.text('Канал сообщества'), findsOneWidget);
    expect(sections.last, 'Сообщества');

    await workspace.currentState!.back();
    await tester.pumpAndSettle();
    expect(sections.last, 'Сообщества');
    expect(await workspace.currentState!.showHome(), isTrue);
    await tester.pumpAndSettle();
    await closed;
    expect(sections.last, isNull);
    expect(tester.takeException(), isNull);
  });
}
