import 'dart:io';
import 'dart:convert';
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:window_manager/window_manager.dart';
import 'package:record/record.dart';
import 'package:path_provider/path_provider.dart';
import 'api.dart';
import 'design.dart';
import 'media_view.dart';
import 'updater.dart';
import 'live_room.dart';
import 'startup_log.dart';
import 'desktop_features.dart';
import 'social_presence.dart';
import 'desktop_discovery.dart';
import 'moderation_center.dart';
import 'command_palette.dart';
import 'platform_console.dart';
import 'desktop_workspace.dart';

const secure = FlutterSecureStorage();
const updateManifest = String.fromEnvironment('CIRCLE_UPDATE_URL');
const updateRepository = String.fromEnvironment('CIRCLE_GITHUB_REPO');
const updatePublicKey = String.fromEnvironment('CIRCLE_UPDATE_PUBLIC_KEY');
const appVersion = '0.10.0';

Uri? get circleUpdateUri => updateManifest.trim().isNotEmpty
    ? Uri.tryParse(updateManifest.trim())
    : CircleUpdater.githubManifestUri(updateRepository.trim());


/// Show Flutter immediately: optional platform services must never block startup.
void main() {
  WidgetsFlutterBinding.ensureInitialized();
  CircleStartupLog.write('Circle Windows $appVersion: bootstrap started');
  FlutterError.onError = (details) {
    CircleStartupLog.report('flutter', details.exception, details.stack);
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (error, stack) {
    CircleStartupLog.report('platform', error, stack);
    return true;
  };
  runApp(const CircleApp());
  WidgetsBinding.instance.addPostFrameCallback((_) {
    CircleStartupLog.write('First Flutter frame callback reached');
    unawaited(configureCircleWindow());
  });
}

Future<void> configureCircleWindow() async {
  try {
    await windowManager.ensureInitialized().timeout(const Duration(seconds: 8));
    await windowManager.waitUntilReadyToShow(
      const WindowOptions(
        size: Size(1390, 870), minimumSize: Size(760, 550),
        center: true, title: 'Circle — Твой круг. Твои люди.',
      ),
      () async {
        await windowManager.show();
        await windowManager.focus();
      },
    ).timeout(const Duration(seconds: 12));
    CircleStartupLog.write('Window manager configured');
  } catch (error, stack) {
    // A window_manager plugin issue must not prevent Flutter from displaying
    // its default native window; preserve the reason for troubleshooting.
    CircleStartupLog.report('window manager', error, stack);
  }
}

class CircleApp extends StatefulWidget {
  const CircleApp({super.key});
  @override State<CircleApp> createState() => _CircleAppState();
}
class _CircleAppState extends State<CircleApp> {
  bool light = false;
  @override Widget build(BuildContext context) => MaterialApp(
    title: 'Circle', debugShowCheckedModeBanner: false,
    theme: circleTheme(), darkTheme: circleTheme(),
    // Preserve the site's graphite/gold identity across the app.
    home: CircleRoot(onTheme: () => setState(() => light = !light), light: light),
    builder: (context, child) => Theme(data: circleTheme(light: light), child: child ?? const SizedBox.shrink()),
  );
}

class CircleRoot extends StatefulWidget {
  const CircleRoot({super.key, required this.onTheme, required this.light});
  final VoidCallback onTheme;
  final bool light;
  @override State<CircleRoot> createState() => _CircleRootState();
}
class _CircleRootState extends State<CircleRoot> {
  CircleApi? api;
  Map<String, dynamic> me = {};
  bool loading = true;
  bool collapsed = false;
  bool incomingDialog = false;
  bool suppressStartupUpdate = false;
  bool incomingPolling = false;
  Timer? incomingTimer;
  Timer? presenceTimer;
  String presence = 'ONLINE';
  bool presenceBusy = false;
  int page = 0;
  final Set<int> visited = {0};
  final workspace = GlobalKey<CircleWorkspaceState>();
  String? workspaceTitle;
  String error = '';
  @override void initState() {
    super.initState();
    restore();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      // Show failures from the previous detached updater instead of silently
      // returning to the old version after a failed file swap.
      unawaited(showLastUpdateResult());
      Future<void>.delayed(const Duration(seconds: 3), () {
        if (mounted) checkUpdatesOnLaunch();
      });
    });
  }

  Future<void> showLastUpdateResult() async {
    final localAppData = Platform.environment['LOCALAPPDATA'];
    if (localAppData == null || localAppData.isEmpty) return;
    final result = File('$localAppData${Platform.pathSeparator}Circle'
        '${Platform.pathSeparator}updates${Platform.pathSeparator}last_result.json');
    if (!await result.exists()) return;
    try {
      final parsed = jsonDecode(await result.readAsString());
      if (parsed is! Map<String, dynamic>) return;
      final state = '${parsed['state'] ?? ''}';
      if (state == 'pending') return;
      await result.delete(); // Consume only completed update attempts.
      if (!mounted || state != 'failed') return;
      suppressStartupUpdate = true;
      final version = '${parsed['version'] ?? 'неизвестна'}';
      final message = '${parsed['message'] ?? 'Неизвестная ошибка'}';
      final logPath = '${parsed['log'] ?? r'%LOCALAPPDATA%\Circle\updates\update.log'}';
      await showDialog<void>(context: context, builder: (dialog) => AlertDialog(
        title: const Text('Circle не удалось обновить'),
        content: SelectableText('Попытка перехода на $version завершилась ошибкой. '
            'Предыдущая версия сохранена.\n\n$message\n\nЖурнал: $logPath'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog),
          child: const Text('Понятно'))],
      ));
    } catch (error, stack) {
      CircleStartupLog.report('update result report', error, stack);
    }
  }

  Future<void> checkUpdatesOnLaunch() async {
    final uri = circleUpdateUri;
    if (uri == null || updatePublicKey.isEmpty || incomingDialog ||
        suppressStartupUpdate || !mounted) return;
    final updater = CircleUpdater(manifestUrl: uri, publicKeyBase64: updatePublicKey);
    try {
      final info = await updater.check(appVersion);
      if (!mounted || info == null) return;
      final accepted = await showDialog<bool>(
        context: context,
        barrierDismissible: true,
        builder: (dialog) => AlertDialog(
          title: Row(children: [const Icon(Icons.auto_awesome, color: circleGold),
            const SizedBox(width: 12), Text('Circle ${info.version}')]),
          content: const Text('Доступно обновление. Скачать проверенные файлы приложения, установить их без переустановки и перезапустить Circle?'),
          actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Позже')),
            FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Обновить'))],
        ),
      );
      if (accepted == true && mounted) {
        openSecondary('Обновление Circle', UpdatesScreen(initialRelease: info));
      }
    } catch (e, stack) {
      // Update availability must never break login or feed rendering.
      CircleStartupLog.report('startup update check', e, stack);
    } finally {updater.close();}
  }
  Future<void> restore() async {
    CircleApi? candidate;
    try {
      final server = await secure.read(key: 'circle_server');
      final token = await secure.read(key: 'circle_token');
      if (server != null && server.isNotEmpty && token != null && token.isNotEmpty) {
        candidate = CircleApi(server)..token = token;
        final data = await candidate.call('me').timeout(const Duration(seconds: 15));
        if (mounted) {
          setState(() {api = candidate; me = obj(data['user']);});
          candidate = null;
          beginIncomingPolling();
          startPresence();
        }
      }
    } catch (error, stack) {
      CircleStartupLog.report('restore session', error, stack);
      // Do not erase a valid token on temporary network or storage failure.
      // The sign-in UI remains usable instead of a perpetual loading spinner.
      if (mounted) setState(() => this.error = 'Не удалось восстановить сессию. Проверьте сеть или войдите снова.');
    } finally {
      candidate?.dispose();
      if (mounted) setState(() => loading = false);
    }
  }

  Future<void> login(String server, String username, String password, String totp) async {
    setState(() {loading = true; error = '';});
    CircleApi? candidate;
    try {
      candidate = CircleApi(server);
      final data = await candidate.call('login', auth: false, body: {'login': username, 'password': password, 'totp_code': totp, 'device': 'Circle Windows Native'});
      candidate.token = '${data['token']}';
      await secure.write(key: 'circle_server', value: server);
      await secure.write(key: 'circle_token', value: candidate.token);
      if (mounted) {setState(() {api?.dispose(); api = candidate; me = obj(data['user']);}); candidate = null; beginIncomingPolling(); startPresence();}
    } catch (e) {if (mounted) setState(() => error = '$e');}
    finally {candidate?.dispose(); if (mounted) setState(() => loading = false);}
  }
  Future<void> logout() async {
    try {await api?.call('logout', body: {});} catch (_) { /* Local sign-out still applies. */ }
    await secure.delete(key: 'circle_token');
    incomingTimer?.cancel(); incomingTimer = null;
    presenceTimer?.cancel(); presenceTimer = null;
    api?.dispose();
    if (mounted) setState(() {api = null; me = {}; page = 0; workspaceTitle = null; visited..clear()..add(0);});
  }
  void openSecondary(String title, Widget child) {
    final screen = CirclePage(title: title, child: child);
    final current = workspace.currentState;
    if (current != null) {
      unawaited(current.open(title, screen));
    } else {
      // Startup updates can also be opened before a user has signed in.
      unawaited(Navigator.push<void>(context,
        MaterialPageRoute<void>(builder: (_) => screen)));
    }
  }
  Future<void> _switchMain(int index) async {
    if (!mounted || api == null) return;
    final current = workspace.currentState;
    if (current != null && !await current.showHome()) return;
    if (!mounted || api == null) return;
    setState(() { page = index; visited.add(index); });
  }

  List<CircleCommand> _quickCommands(CircleApi client) => [
    CircleCommand(title: 'Главная', subtitle: 'Новости и публикации',
      icon: Icons.home_rounded, keyHint: 'Ctrl+1', onInvoke: () => _switchMain(0)),
    CircleCommand(title: 'Профиль', subtitle: 'Моя страница и оформление',
      icon: Icons.person_outline_rounded, keyHint: 'Ctrl+2', onInvoke: () => _switchMain(1)),
    CircleCommand(title: 'Мессенджер', subtitle: 'Личные диалоги и Избранное',
      icon: Icons.forum_outlined, keyHint: 'Ctrl+3', onInvoke: () => _switchMain(2)),
    CircleCommand(title: 'Друзья', subtitle: 'Контакты и заявки',
      icon: Icons.people_outline_rounded, keyHint: 'Ctrl+4', onInvoke: () => _switchMain(3)),
    CircleCommand(title: 'Сообщества', subtitle: 'Сообщества и каналы',
      icon: Icons.groups_2_outlined,
      onInvoke: () => openSecondary('Сообщества', CommunitiesScreen(client))),
    CircleCommand(title: 'Поиск сообщений', subtitle: 'Поиск по перепискам и каналам',
      icon: Icons.manage_search_rounded,
      onInvoke: () => openSecondary('Поиск', CircleMessageSearchScreen(api: client,
        onOpenChannel: (id, name) => openSecondary(name, ChannelScreen(client, id, name)),
        onOpenConversation: (id) => openSecondary('Переписка',
          MessagesScreen(client, id, peer: const {'display_name': 'Переписка'}, me: me))))),
    CircleCommand(title: 'Кинозалы', subtitle: 'Совместный просмотр',
      icon: Icons.local_movies_outlined,
      onInvoke: () => openSecondary('Кинозалы', CinemaRoomsScreen(client))),
    CircleCommand(title: 'Групповые встречи', subtitle: 'Голосовая связь и видео',
      icon: Icons.groups_3_outlined,
      onInvoke: () => openSecondary('Встречи', DesktopMeetingsScreen(client))),
    CircleCommand(title: 'Безопасность', subtitle: 'Устройства и двухфакторная защита',
      icon: Icons.security_outlined,
      onInvoke: () => openSecondary('Безопасность', DesktopSecurityScreen(client))),
    CircleCommand(title: 'Уведомления', subtitle: 'События из твоего круга',
      icon: Icons.notifications_none,
      onInvoke: () => openSecondary('Уведомления', NotificationsScreen(client))),
    CircleCommand(title: 'Обновления', subtitle: 'Проверка версии и установка',
      icon: Icons.system_update_alt_rounded,
      onInvoke: () => openSecondary('Обновления', const UpdatesScreen())),
    if (['OWNER','ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
      CircleCommand(title: 'Системы платформы', subtitle: 'Модули и журнал действий',
        icon: Icons.tune_rounded,
        onInvoke: () => openSecondary('Системы Circle', CirclePlatformConsole(client))),
    if (['OWNER','ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
      CircleCommand(title: 'Жалобы и архив', subtitle: 'Обращения и журнал решений',
        icon: Icons.fact_check_outlined,
        onInvoke: () => openSecondary('Модерация', CircleModerationCenter(client,
          onOpenUser: (id) => openSecondary('Профиль', PublicProfile(client, id))))),
  ];

  void _openPalette() {
    final client = api;
    if (!mounted || client == null) return;
    showCircleCommandPalette(context, _quickCommands(client));
  }

  void beginIncomingPolling() {
    incomingTimer?.cancel();
    incomingTimer = Timer.periodic(const Duration(seconds: 9), (_) => pollIncoming());
  }
  void startPresence() {
    presenceTimer?.cancel();
    unawaited(loadPresence());
    unawaited(pingPresence()); // Visible immediately after login, not 45 seconds later.
    presenceTimer = Timer.periodic(const Duration(seconds: 45), (_) {
      if (WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed) {
        unawaited(pingPresence());
      }
    });
  }
  Future<void> loadPresence() async {
    try {
      final result = await api?.call('desktop-presence');
      final status = '${result?['status'] ?? 'ONLINE'}';
      if (mounted && circlePresenceLabels.containsKey(status)) setState(() => presence = status);
    } catch (_) { // Older servers may not yet have the Desktop API patch.
    }
  }
  Future<void> pingPresence() async {
    if (presenceBusy || api == null) return;
    presenceBusy = true;
    try {await api!.call('desktop-presence-ping', body: {});} catch (_) {}
    finally {presenceBusy = false;}
  }
  Future<void> setPresence(String status) async {
    if (api == null || !circlePresenceLabels.containsKey(status) || status == 'OFFLINE') return;
    final original = presence;
    setState(() => presence = status);
    try {await api!.call('desktop-presence-set', body: {'status': status});}
    catch (error) {
      if (mounted) {setState(() => presence = original); notify(context, 'Не удалось изменить статус: $error');}
    }
  }

  Future<void> pollIncoming() async {
    if (api == null || incomingDialog || incomingPolling || !mounted ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.paused ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.hidden) return;
    incomingPolling = true;
    final client = api!;
    try {
      final response = await client.call('mobile-call-poll');
      final incoming = obj(response['call']);
      if (incoming.isEmpty || !mounted || incomingDialog) return;
      incomingDialog = true;
      final callId = identifier(incoming['call_id']);
      final conversation = identifier(incoming['conversation_id']);
      final rawId = identifier(incoming['id']);
      final person = obj(incoming['peer']);
      final accepted = await showDialog<bool>(context: context, barrierDismissible: false, builder: (dialog) => AlertDialog(
        title: const Text('Входящий звонок'), content: Column(mainAxisSize: MainAxisSize.min, children: [CircleUserAvatar(api: client, user: person, radius: 38), const SizedBox(height: 14), Text(label(person), style: Theme.of(dialog).textTheme.titleLarge)]),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Отклонить')), FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Принять'))],
      ));
      if (accepted == true) {
        await client.call('mobile-call-accept', body: {'call_id': callId, 'conversation_id': conversation, 'notification_id': rawId < 0 ? -rawId : rawId});
        if (mounted) {
          await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CircleLiveRoom(
            title: 'Звонок · ${label(person)}',
            credentials: () => client.call('mobile-call-token', body: {'conversation_id': conversation, 'call_id': callId}),
            onFinish: callId > 0 ? () async {await client.call('mobile-call-finish', body: {'call_id': callId, 'conversation_id': conversation});} : null,
          )));
        }
      } else {
        await client.call('mobile-call-decline', body: {'call_id': callId, 'notification_id': rawId < 0 ? -rawId : rawId});
      }
    } catch (_) { /* Polling must not interrupt navigation when calls are disabled. */ }
    finally {incomingDialog = false; incomingPolling = false;}
  }
  @override void dispose() {incomingTimer?.cancel(); presenceTimer?.cancel(); api?.dispose(); super.dispose();}
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: CircleAmbientBackground(child: CircleLoadingState(caption: 'Открываем Circle...')));
    if (api == null) return LoginScreen(onLogin: login, error: error);
    final client = api!;
    final small = MediaQuery.sizeOf(context).width < 970;
    final mini = small || collapsed;
    final width = mini ? 78.0 : 246.0;
    final screens = <Widget>[
      if (visited.contains(0)) FeedScreen(client) else const SizedBox.shrink(),
      if (visited.contains(1)) ProfileScreen(client) else const SizedBox.shrink(),
      if (visited.contains(2)) MessengerScreen(client, me: me) else const SizedBox.shrink(),
      if (visited.contains(3)) FriendsScreen(client) else const SizedBox.shrink(),
    ];
    final names = ['Главная', 'Профиль', 'Мессенджер', 'Друзья'];
    final subtitles = ['Новости твоего круга', 'Твоя страница и публикации',
      'Личные разговоры и Избранное', 'Люди, с которыми ты на связи'];
    final icons = [Icons.home_rounded, Icons.account_circle_outlined, Icons.forum_outlined, Icons.people_outline_rounded];
    return CallbackShortcuts(bindings: <ShortcutActivator, VoidCallback>{
      const SingleActivator(LogicalKeyboardKey.keyK, control: true): _openPalette,
      const SingleActivator(LogicalKeyboardKey.digit1, control: true): () => _switchMain(0),
      const SingleActivator(LogicalKeyboardKey.digit2, control: true): () => _switchMain(1),
      const SingleActivator(LogicalKeyboardKey.digit3, control: true): () => _switchMain(2),
      const SingleActivator(LogicalKeyboardKey.digit4, control: true): () => _switchMain(3),
      const SingleActivator(LogicalKeyboardKey.arrowLeft, alt: true): () {
        unawaited(workspace.currentState?.back());
      },
    }, child: Focus(autofocus: true, child: Scaffold(body: Row(children: [
      AnimatedContainer(duration: CircleMotion.duration(context, CircleMotion.normal), width: width,
        decoration: BoxDecoration(
          gradient: widget.light ? null : const LinearGradient(begin: Alignment.topCenter,
            end: Alignment.bottomCenter, colors: [Color(0xFF151619), Color(0xFF111215)]),
          color: widget.light ? const Color(0xFFEAE5DC) : null,
          border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
        child: ClipRect(child: OverflowBox(alignment: Alignment.topLeft,
          minWidth: width, maxWidth: width,
          child: SafeArea(child: Column(children: [
          Padding(padding: EdgeInsets.fromLTRB(mini ? 16 : 19, 22, 8, 22), child: CircleLogo(compact: mini, size: 43)),
          Expanded(child: ListView(key: const PageStorageKey('workspace-navigation'), children: [
          for (var i = 0; i < names.length; i++) CircleNavItem(
            key: ValueKey('main-nav-$i'), icon: icons[i], title: names[i],
            active: workspaceTitle == null && page == i, compact: mini,
            onTap: () => _switchMain(i),
          ),
          const SizedBox(height: 18),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Divider(color: Theme.of(context).dividerColor)),
          if (!mini) Padding(padding: const EdgeInsets.fromLTRB(20, 10, 8, 9), child: Text('РАЗДЕЛЫ', style: Theme.of(context).textTheme.bodySmall?.copyWith(letterSpacing: 2, fontSize: 10))),
          _secondaryNav(mini, Icons.manage_search_rounded, 'Поиск сообщений',
            () => openSecondary('Поиск сообщений', CircleMessageSearchScreen(
              api: client,
              onOpenChannel: (id, name) => openSecondary(name, ChannelScreen(client, id, name)),
              onOpenConversation: (id) => openSecondary('Переписка',
                MessagesScreen(client, id, peer: const {'display_name':'Переписка'}, me: me)),
            ))),
          _secondaryNav(mini, Icons.circle_outlined, 'Кто в сети', () => openSecondary('Люди в сети', CirclePeopleOnlineScreen(client,
            onOpenUser: (id) => openSecondary('Профиль', PublicProfile(client, id))))),
          _secondaryNav(mini, Icons.groups_2_outlined, 'Сообщества', () => openSecondary('Сообщества', CommunitiesScreen(client))),
          _secondaryNav(mini, Icons.call_outlined, 'Звонки', () => openSecondary('Звонки', CallsScreen(client))),
          _secondaryNav(mini, Icons.local_movies_outlined, 'Кинозалы', () => openSecondary('Кинозалы', CinemaRoomsScreen(client))),
          _secondaryNav(mini, Icons.groups_3_outlined, 'Групповые встречи', () => openSecondary('Групповые встречи', DesktopMeetingsScreen(client))),
          _secondaryNav(mini, Icons.security_outlined, 'Безопасность', () => openSecondary('Безопасность', DesktopSecurityScreen(client))),
          if (['OWNER', 'ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
            _secondaryNav(mini, Icons.tune_rounded, 'Системы платформы',
              () => openSecondary('Системы Circle', CirclePlatformConsole(client))),
          if (['OWNER', 'ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
            _secondaryNav(mini, Icons.fact_check_outlined, 'Жалобы и архив',
              () => openSecondary('Модерация', CircleModerationCenter(client,
                onOpenUser: (id) => openSecondary('Профиль', PublicProfile(client, id))))),
          if (['OWNER', 'ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
            _secondaryNav(mini, Icons.admin_panel_settings_outlined, 'Администрирование', () => openSecondary('Администрирование', AdminSummaryScreen(client))),
          if (['OWNER', 'ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
            _secondaryNav(mini, Icons.policy_outlined, 'Trust & Safety', () => openSecondary('Trust & Safety', DesktopTrustScreen(client))),
          _secondaryNav(mini, Icons.settings_outlined, 'Обновления', () => openSecondary('Обновления', const UpdatesScreen())),
          const SizedBox(height: 12),
          ])),
          if (!mini) Padding(padding: const EdgeInsets.fromLTRB(21, 8, 10, 3), child: Text('CIRCLE WINDOWS · $appVersion',
            style: const TextStyle(color: circleMuted, fontSize: 9, letterSpacing: 1.5))),
          const SizedBox(height: 10),
          Padding(padding: EdgeInsets.all(mini ? 8 : 12), child: Tooltip(message: 'Мой профиль', child: InkWell(onTap: () => _switchMain(1), borderRadius: BorderRadius.circular(13),
            child: Container(padding: EdgeInsets.all(mini ? 6 : 9), decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), color: circleGold.withValues(alpha: .07)),
              child: Row(mainAxisAlignment: mini ? MainAxisAlignment.center : MainAxisAlignment.start, children: [CircleUserAvatar(api: client, user: me, radius: 19), if (!mini) ...[const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(me), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), Text('@${me['username'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: circleMuted))]))]]))))),
        ]))))),
      Expanded(child: CircleWorkspace(key: workspace,
        onRouteChanged: (title) {
          if (mounted && workspaceTitle != title) setState(() => workspaceTitle = title);
        },
        home: CircleAmbientBackground(
        child: Column(children: [
        CircleWorkspaceHeader(title: names[page], subtitle: subtitles[page],
          leading: IconButton(
            tooltip: small ? 'Компактная навигация для узкого окна'
              : mini ? 'Развернуть меню' : 'Свернуть меню',
            onPressed: small ? null : () => setState(() => collapsed = !collapsed),
            icon: Icon(mini ? Icons.menu_open_rounded : Icons.menu_rounded)),
          actionsBuilder: (context, compact) => _headerActions(client, compact)),
        Expanded(child: IndexedStack(index: page, children: [
          for (var i = 0; i < screens.length; i++) TickerMode(
            enabled: i == page,
            child: RepaintBoundary(child: AnimatedOpacity(
              opacity: i == page ? 1 : 0,
              duration: CircleMotion.duration(context, CircleMotion.normal),
              curve: Curves.easeOutCubic,
              child: AnimatedSlide(
                offset: i == page ? Offset.zero : const Offset(.022, 0),
                duration: CircleMotion.duration(context, CircleMotion.normal),
                curve: Curves.easeOutCubic,
                child: screens[i],
              ),
            )))])),
      ])))),
    ]))));
  }

  List<Widget> _headerActions(CircleApi client, bool compact) => [
    CircleIconAction(tooltip: 'Быстрый переход · Ctrl+K',
      onPressed: _openPalette, icon: Icons.search_rounded),
    PopupMenuButton<String>(tooltip: 'Статус присутствия',
      onSelected: setPresence,
      itemBuilder: (_) => ['ONLINE', 'IDLE', 'DND'].map((status) =>
        PopupMenuItem<String>(value: status, child: Row(children: [
          CirclePresenceIndicator(status: status), const SizedBox(width: 12),
          Expanded(child: Text(circlePresenceLabels[status]!)),
          if (presence == status) const Icon(Icons.check, size: 16, color: circleGold),
        ]))).toList(),
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 12),
        child: Semantics(button: true, label: 'Статус: ${circlePresenceLabels[presence]}',
          child: CirclePresenceIndicator(status: presence, showText: !compact)))),
    if (!compact) ...[
      CircleIconAction(tooltip: 'Сообщества', icon: Icons.groups_outlined,
        onPressed: () => openSecondary('Сообщества', CommunitiesScreen(client))),
      CircleIconAction(tooltip: 'Звонки', icon: Icons.call_outlined,
        onPressed: () => openSecondary('Звонки', CallsScreen(client))),
    ],
    CircleIconAction(tooltip: 'Уведомления', icon: Icons.notifications_none,
      onPressed: () => openSecondary('Уведомления', NotificationsScreen(client))),
    if (!compact) CircleIconAction(tooltip: 'Переключить тему',
      onPressed: widget.onTheme,
      icon: widget.light ? Icons.dark_mode_outlined : Icons.light_mode_outlined),
    if (compact) PopupMenuButton<String>(tooltip: 'Другие действия',
      icon: const Icon(Icons.more_horiz_rounded),
      onSelected: (value) {
        if (value == 'communities') openSecondary('Сообщества', CommunitiesScreen(client));
        if (value == 'calls') openSecondary('Звонки', CallsScreen(client));
        if (value == 'theme') widget.onTheme();
      },
      itemBuilder: (_) => [
        const PopupMenuItem(value: 'communities', child: Text('Сообщества')),
        const PopupMenuItem(value: 'calls', child: Text('Звонки')),
        PopupMenuItem(value: 'theme', child: Text(widget.light ? 'Тёмная тема' : 'Светлая тема')),
      ]),
    PopupMenuButton<String>(tooltip: 'Аккаунт',
      onSelected: (choice) {
        if (choice == 'logout') logout();
        if (choice == 'updates') openSecondary('Обновления', const UpdatesScreen());
        if (choice == 'profile') _switchMain(1);
      },
      itemBuilder: (_) => const [
        PopupMenuItem(value: 'profile', child: Text('Мой профиль')),
        PopupMenuItem(value: 'updates', child: Text('Обновления Circle')),
        PopupMenuDivider(),
        PopupMenuItem(value: 'logout', child: Text('Выйти из аккаунта')),
      ],
      child: Padding(padding: const EdgeInsets.only(left: 9),
        child: CircleUserAvatar(api: client, user: me, radius: 17))),
  ];

  Widget _secondaryNav(bool mini, IconData icon, String title, VoidCallback tap) {
    final active = workspaceTitle == title ||
        (title == 'Жалобы и архив' && workspaceTitle == 'Модерация') ||
        (title == 'Системы платформы' && workspaceTitle == 'Системы Circle') ||
        (title == 'Кто в сети' && workspaceTitle == 'Люди в сети');
    return CircleNavItem(icon: icon, title: title, compact: mini,
      active: active, onTap: active ? () {} : tap);
  }
}

class CirclePage extends StatelessWidget {
  const CirclePage({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(toolbarHeight: 69, titleSpacing: 4,
      title: Row(children: [Container(width: 3, height: 24,
        decoration: BoxDecoration(color: circleGoldBright,
          borderRadius: BorderRadius.circular(4),
          boxShadow: [BoxShadow(color: circleGold.withValues(alpha: .32), blurRadius: 12)])),
        const SizedBox(width: 13), Expanded(child: Text(title,
          maxLines: 1, overflow: TextOverflow.ellipsis))]),
      leading: IconButton(tooltip: 'Назад',
        icon: const Icon(Icons.arrow_back_rounded), onPressed: () => Navigator.pop(context))),
    body: CircleAmbientBackground(child: child));
}

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, required this.onLogin, required this.error});
  final Future<void> Function(String, String, String, String) onLogin;
  final String error;
  @override State<LoginScreen> createState() => _LoginScreenState();
}
class _LoginScreenState extends State<LoginScreen> {
  final host = TextEditingController(text: 'https://acircle.ru');
  final user = TextEditingController();
  final pass = TextEditingController();
  final totp = TextEditingController();
  bool reveal = false;
  @override void dispose() {for (final controller in [host, user, pass, totp]) {controller.dispose();} super.dispose();}
  @override Widget build(BuildContext context) {
    final wide = MediaQuery.sizeOf(context).width > 940;
    return Scaffold(body: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
      child: Container(constraints: const BoxConstraints(maxWidth: 1060),
        decoration: BoxDecoration(borderRadius: BorderRadius.circular(24), border: Border.all(color: circleStroke), color: circlePanel, boxShadow: const [BoxShadow(color: Colors.black26, blurRadius: 48, offset: Offset(0, 18))]),
        clipBehavior: Clip.antiAlias,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (wide) Expanded(child: Container(height: 590, padding: const EdgeInsets.all(55), decoration: BoxDecoration(gradient: LinearGradient(colors: [circleGold.withValues(alpha: .13), circlePanel, circleSidebar], begin: Alignment.topLeft, end: Alignment.bottomRight)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const CircleLogo(size: 54), const Spacer(),
              const Text('Всё важное —\nв твоём круге.', style: TextStyle(fontSize: 40, fontWeight: FontWeight.w800, letterSpacing: -1.4, height: 1.16)),
              const SizedBox(height: 20), const Text('Люди, новости, сообщества и разговоры.\nВ одном пространстве, которое принадлежит тебе.', style: TextStyle(color: circleMuted, fontSize: 15, height: 1.6)),
              const SizedBox(height: 34), Container(height: 2, width: 85, decoration: BoxDecoration(color: circleGold, borderRadius: BorderRadius.circular(4))),
            ]))),
          Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 42, vertical: 55), child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
            if (!wide) ...[const CircleLogo(), const SizedBox(height: 30)],
            Text('С возвращением', style: Theme.of(context).textTheme.headlineMedium),
            const SizedBox(height: 10), const Text('Войдите в Circle, чтобы продолжить общение.', style: TextStyle(color: circleMuted)),
            const SizedBox(height: 32),
            TextField(controller: host, decoration: const InputDecoration(labelText: 'Адрес сервера', prefixIcon: Icon(Icons.dns_outlined))),
            const SizedBox(height: 13),
            TextField(controller: user, decoration: const InputDecoration(labelText: 'Логин или email', prefixIcon: Icon(Icons.alternate_email)), textInputAction: TextInputAction.next),
            const SizedBox(height: 13),
            TextField(controller: pass, obscureText: !reveal, onSubmitted: (_) => _submit(), decoration: InputDecoration(labelText: 'Пароль', prefixIcon: const Icon(Icons.lock_outline), suffixIcon: IconButton(onPressed: () => setState(() => reveal = !reveal), icon: Icon(reveal ? Icons.visibility_off_outlined : Icons.visibility_outlined)))),
            const SizedBox(height: 13),
            TextField(controller: totp, decoration: const InputDecoration(labelText: 'Код 2FA (при необходимости)', prefixIcon: Icon(Icons.shield_outlined))),
            if (widget.error.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 14), child: Text(widget.error, style: const TextStyle(color: circleRed))),
            const SizedBox(height: 24), SizedBox(width: double.infinity, child: CircleAccentButton(
              label: 'Войти в Circle', icon: Icons.login_rounded, onPressed: _submit)),
            const SizedBox(height: 15), Row(mainAxisAlignment: MainAxisAlignment.center, children: [
              TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
                builder: (_) => AuthSupportScreen(server: host.text.trim(), register: true))),
                child: const Text('Создать аккаунт')),
              const SizedBox(width: 14),
              TextButton(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
                builder: (_) => AuthSupportScreen(server: host.text.trim(), register: false))),
                child: const Text('Забыли пароль?')),
            ]),
            const SizedBox(height: 12), const Center(child: Text('Circle · Нативный клиент для Windows', style: TextStyle(color: circleMuted, fontSize: 11))),
          ]))),
        ])),
    )));
  }
  void _submit() {widget.onLogin(host.text.trim(), user.text.trim(), pass.text, totp.text.trim());}
}

/// Account creation and password recovery are native API screens.
class AuthSupportScreen extends StatefulWidget {
  const AuthSupportScreen({super.key, required this.server, required this.register});
  final String server;
  final bool register;
  @override State<AuthSupportScreen> createState() => _AuthSupportScreenState();
}
class _AuthSupportScreenState extends State<AuthSupportScreen> {
  final name = TextEditingController();
  final email = TextEditingController();
  final nickname = TextEditingController();
  final password = TextEditingController();
  bool busy = false;
  String message = '';
  @override void dispose() {
    for (final field in [name, email, nickname, password]) {field.dispose();}
    super.dispose();
  }
  Future<void> submit() async {
    if (busy) return;
    setState(() {busy = true; message = '';});
    CircleApi? api;
    try {
      api = CircleApi(widget.server);
      final result = await api.call(widget.register ? 'register' : 'forgot-password',
        auth: false, body: widget.register ? {
          'username': nickname.text.trim(), 'display_name': name.text.trim(),
          'email': email.text.trim(), 'password': password.text,
        } : {'email': email.text.trim()});
      if (!mounted) return;
      setState(() => message = widget.register
        ? result['email_verification'] == true
          ? 'Аккаунт создан. Подтверди адрес электронной почты и войди.'
          : 'Аккаунт создан. Теперь можно войти.'
        : 'Если аккаунт существует, на почту отправлено письмо.');
    } catch (e) {if (mounted) setState(() => message = '$e');}
    finally {api?.dispose(); if (mounted) setState(() => busy = false);}
  }
  @override Widget build(BuildContext context) => CirclePage(
    title: widget.register ? 'Регистрация' : 'Восстановление доступа',
    child: Center(child: SingleChildScrollView(padding: const EdgeInsets.all(24),
      child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 480),
        child: CircleSurface(accent: true, padding: const EdgeInsets.all(28),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start,
            children: [const CircleLogo(size: 42), const SizedBox(height: 26),
              Text(widget.register ? 'Стань частью круга' : 'Верни доступ к Circle',
                style: Theme.of(context).textTheme.headlineSmall),
              const SizedBox(height: 12),
              if (widget.register) ...[
                TextField(controller: name, maxLength: 60, decoration: const InputDecoration(labelText: 'Отображаемое имя')),
                const SizedBox(height: 8),
                TextField(controller: nickname, maxLength: 24, decoration: const InputDecoration(labelText: 'Никнейм (латиница)')),
                const SizedBox(height: 8),
              ],
              TextField(controller: email, keyboardType: TextInputType.emailAddress,
                decoration: const InputDecoration(labelText: 'Электронная почта')),
              if (widget.register) ...[
                const SizedBox(height: 15),
                TextField(controller: password, obscureText: true,
                  decoration: const InputDecoration(labelText: 'Пароль (минимум 8 символов)')),
              ],
              if (message.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 15), child: Text(message)),
              const SizedBox(height: 22), SizedBox(width: double.infinity,
                child: FilledButton(onPressed: busy ? null : submit,
                  child: Text(busy ? 'Отправка...' : widget.register ? 'Зарегистрироваться' : 'Восстановить доступ'))),
            ]))))));
}

void notify(BuildContext context, String message) {
  if (!context.mounted) return;
  ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
}
Future<String?> compose(BuildContext context, String title, {String initial = '', int maxLength = 4000}) async {
  final controller = TextEditingController(text: initial);
  final result = await showDialog<String>(context: context, builder: (dialogContext) => AlertDialog(
    title: Text(title), content: SizedBox(width: 490, child: TextField(controller: controller, maxLines: 5, minLines: 2, maxLength: maxLength, autofocus: true)),
    actions: [TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('Отмена')), FilledButton(onPressed: () => Navigator.pop(dialogContext, controller.text.trim()), child: const Text('Сохранить'))],
  ));
  controller.dispose();
  return result;
}

class ApiList extends StatefulWidget {
  const ApiList({super.key, required this.api, required this.route, required this.itemBuilder, this.query = const {}, this.emptyTitle = 'Здесь пока ничего нет', this.padding = const EdgeInsets.all(20)});
  final CircleApi api;
  final String route;
  final Map<String, String> query;
  final String emptyTitle;
  final EdgeInsets padding;
  final Widget Function(BuildContext, Map<String, dynamic>, VoidCallback) itemBuilder;
  @override State<ApiList> createState() => _ApiListState();
}
class _ApiListState extends State<ApiList> {
  late Future<List<Map<String, dynamic>>> future;
  @override void initState() {super.initState(); _reload();}
  @override void didUpdateWidget(covariant ApiList oldWidget) {super.didUpdateWidget(oldWidget); if (oldWidget.api != widget.api || oldWidget.route != widget.route || oldWidget.query.toString() != widget.query.toString()) _reload();}
  void _reload() {future = widget.api.call(widget.route, query: widget.query).then(items);}
  void refresh() {if (mounted) setState(_reload);}
  @override Widget build(BuildContext context) => FutureBuilder<List<Map<String, dynamic>>>(future: future, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Не удалось загрузить данные', description: '${snapshot.error}', icon: Icons.wifi_off_rounded, action: OutlinedButton(onPressed: refresh, child: const Text('Повторить')));
    if (!snapshot.hasData) return const CircleLoadingState();
    final data = snapshot.data!;
    return RefreshIndicator(onRefresh: () async {refresh(); await future;}, child: data.isEmpty
      ? ListView(children: [SizedBox(height: 350, child: CircleEmpty(title: widget.emptyTitle, icon: Icons.inbox_outlined))])
      : ListView.builder(padding: widget.padding, itemCount: data.length,
          cacheExtent: 300,
          itemBuilder: (context, index) => Padding(
            key: ValueKey('${widget.route}-${identifier(data[index]['id'])}'),
            padding: const EdgeInsets.only(bottom: 12),
            child: widget.itemBuilder(context, data[index], refresh))));
  });
}

class FeedScreen extends StatefulWidget {
  const FeedScreen(this.api, {super.key, this.route = 'feed', this.query = const {}});
  final CircleApi api;
  final String route;
  final Map<String, String> query;
  @override State<FeedScreen> createState() => _FeedScreenState();
}
class _FeedScreenState extends State<FeedScreen> {
  late Future<List<Map<String, dynamic>>> posts;
  @override void initState() {super.initState(); reloadPosts();}
  @override void didUpdateWidget(covariant FeedScreen old) {
    super.didUpdateWidget(old);
    if (old.api != widget.api || old.route != widget.route ||
        old.query.toString() != widget.query.toString()) reloadPosts();
  }
  void reloadPosts() {
    posts = widget.api.call(widget.route, query: widget.query).then(items);
  }
  Future<void> refresh() async {
    setState(reloadPosts);
    try {await posts;} catch (_) { /* Error state is rendered below. */ }
  }
  Future<void> createPost({bool media = false}) async {
    final title = await compose(context, 'Заголовок публикации', maxLength: 140);
    if (!mounted || title == null || title.isEmpty) return;
    final body = await compose(context, 'Текст публикации', maxLength: 4000);
    if (!mounted || body == null) return;
    try {
      if (media) {
        final picked = await FilePicker.platform.pickFiles(type: FileType.custom,
          allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm']);
        if (picked == null || picked.files.single.path == null) return;
        await widget.api.upload('post-upload', File(picked.files.single.path!),
          field: 'media', fields: {'title': title, 'body': body});
      } else {
        await widget.api.call('post-create', body: {'title': title, 'body': body});
      }
      if (mounted) {notify(context, 'Публикация создана'); setState(reloadPosts);}
    } catch (error) {if (mounted) notify(context, '$error');}
  }
  @override Widget build(BuildContext context) {
    final isHome = widget.route == 'feed';
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1010),
      child: RefreshIndicator(color: circleGoldBright, onRefresh: refresh,
        child: CustomScrollView(
          physics: const AlwaysScrollableScrollPhysics(),
          slivers: [
            if (isHome) ...[
              const SliverToBoxAdapter(child: Padding(
                padding: EdgeInsets.fromLTRB(24, 28, 24, 14),
                child: CircleSection(title: 'Твой круг', subtitle: 'Люди, события и истории, которые тебе близки'))),
              SliverToBoxAdapter(child: SizedBox(height: 128, child: StoriesStrip(widget.api))),
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(24, 8, 24, 22),
                child: CircleSurface(padding: const EdgeInsets.all(19), accent: true,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [const Icon(Icons.edit_square, color: circleGold, size: 22),
                      const SizedBox(width: 11), Expanded(child: Text('Есть чем поделиться?',
                        style: Theme.of(context).textTheme.titleMedium))]),
                    const SizedBox(height: 15),
                    Wrap(spacing: 10, runSpacing: 10, children: [
                      CircleAccentButton(label: 'Новая публикация',
                        icon: Icons.add_rounded, onPressed: () => createPost()),
                      CircleAccentButton(label: 'Фото / видео', icon: Icons.image_outlined,
                        primary: false, onPressed: () => createPost(media: true)),
                    ]),
                  ])))),
              SliverToBoxAdapter(child: Padding(
                padding: const EdgeInsets.fromLTRB(26, 0, 24, 14),
                child: Row(children: [
                  const Icon(Icons.auto_awesome_outlined, color: circleGold, size: 16),
                  const SizedBox(width: 8), Text('НОВОСТИ',
                    style: Theme.of(context).textTheme.bodySmall?.copyWith(
                      fontSize: 11, letterSpacing: 1.7, fontWeight: FontWeight.w700)),
                ]))),
            ],
            FutureBuilder<List<Map<String, dynamic>>>(future: posts, builder: (context, snapshot) {
              if (snapshot.hasError) return SliverFillRemaining(hasScrollBody: false,
                child: CircleEmpty(title: 'Лента недоступна', description: '${snapshot.error}',
                  icon: Icons.wifi_off_rounded,
                  action: CircleAccentButton(label: 'Повторить', primary: false,
                    onPressed: () => setState(reloadPosts))));
              if (!snapshot.hasData) return const SliverFillRemaining(
                hasScrollBody: false, child: CircleLoadingState(caption: 'Подбираем публикации...'));
              final entries = snapshot.data!;
              if (entries.isEmpty) return SliverFillRemaining(hasScrollBody: false,
                child: CircleEmpty(title: isHome ? 'Лента пока пуста' : 'Публикаций пока нет',
                  description: 'Новые записи появятся здесь.', icon: Icons.dynamic_feed_outlined));
              return SliverPadding(
                padding: const EdgeInsets.fromLTRB(24, 0, 24, 34),
                sliver: SliverList.builder(itemCount: entries.length,
                  itemBuilder: (context, index) => Padding(
                    key: ValueKey('${widget.route}-${identifier(entries[index]['id'])}'),
                    padding: const EdgeInsets.only(bottom: 13),
                    child: PostCard(widget.api, entries[index], () => setState(reloadPosts)))));
            }),
          ],
        ),
      ),
    ));
  }
}

class PostCard extends StatelessWidget {
  const PostCard(this.api, this.post, this.refresh, {super.key});
  final CircleApi api;
  final Map<String, dynamic> post;
  final VoidCallback refresh;
  @override Widget build(BuildContext context) {
    final author = obj(post['author']);
    final community = obj(post['community']);
    final stats = obj(post['stats']);
    final id = identifier(post['id']);
    final title = '${post['title'] ?? ''}';
    final body = '${post['body'] ?? ''}';
    return CircleSurface(padding: const EdgeInsets.all(21), interactive: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [CircleUserAvatar(api: api, user: author, radius: 21), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Flexible(child: Text(label(author), overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)), if (author['verified'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.verified_rounded, color: circleGold, size: 16))]),
          const SizedBox(height: 3), Text('${circleDate(post['created_at'])}${community.isEmpty ? '' : '  ·  ${community['name'] ?? ''}'}', style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        if (post['can_edit'] == true) PopupMenuButton<String>(
          tooltip: 'Управление публикацией',
          icon: const Icon(Icons.more_horiz_rounded, color: circleMuted),
          onSelected: (action) async {
            try {
              if (action == 'delete') {
                final approved = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
                  title: const Text('Удалить публикацию?'),
                  content: const Text('Удаление публикации и её комментариев нельзя отменить.'),
                  actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Отмена')),
                    FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Удалить'))],
                ));
                if (approved != true) return;
                await api.call('post-delete', body: {'post_id': id});
              } else if (action == 'pin') {
                await api.call('post-pin', body: {'post_id': id});
              } else if (action == 'comments') {
                await api.call('post-edit', body: {'post_id': id, 'field': 'comments', 'enabled': post['comments_enabled'] != true});
              } else {
                final field = action == 'title' ? 'title' : 'body';
                final text = await compose(context, field == 'title' ? 'Изменить заголовок' : 'Изменить текст',
                  initial: field == 'title' ? title : body, maxLength: field == 'title' ? 140 : 4000);
                if (text == null || (field == 'title' && text.trim().isEmpty)) return;
                await api.call('post-edit', body: {'post_id': id, 'field': field, 'value': text});
              }
              if (context.mounted) refresh();
            } catch (error) {if (context.mounted) notify(context, '$error');}
          },
          itemBuilder: (_) => [
            const PopupMenuItem(value: 'title', child: Text('Изменить заголовок')),
            const PopupMenuItem(value: 'body', child: Text('Изменить текст')),
            PopupMenuItem(value: 'comments', child: Text(post['comments_enabled'] == true ? 'Отключить комментарии' : 'Включить комментарии')),
            if (community.isEmpty) PopupMenuItem(value: 'pin', child: Text(post['is_pinned'] == true ? 'Открепить' : 'Закрепить в профиле')),
            const PopupMenuDivider(),
            const PopupMenuItem(value: 'delete', child: Text('Удалить публикацию', style: TextStyle(color: circleRed))),
          ],
        ),
      ]),
      if (post['is_pinned'] == true) const Padding(padding: EdgeInsets.only(top: 12), child: Row(children: [Icon(Icons.push_pin, size: 13, color: circleGold), SizedBox(width: 6), Text('Закреплённая публикация', style: TextStyle(color: circleGold, fontSize: 11))])),
      if (title.isNotEmpty) ...[const SizedBox(height: 16), Text(title, style: Theme.of(context).textTheme.titleLarge)],
      if (body.isNotEmpty) ...[const SizedBox(height: 9), SelectableText(body, style: Theme.of(context).textTheme.bodyMedium)],
      if (post['has_media'] == true) Padding(padding: const EdgeInsets.only(top: 15), child: CircleMedia(api: api, route: 'post-media', id: id, mime: '${post['media_mime'] ?? ''}')),
      const SizedBox(height: 14), Divider(color: Theme.of(context).dividerColor, height: 1),
      const SizedBox(height: 10), Wrap(spacing: 15, runSpacing: 5, children: [
        TextButton.icon(onPressed: () async {try {await api.call('post-like', body: {'post_id': id}); refresh();} catch (e) {if (context.mounted) notify(context, '$e');}}, icon: AnimatedSwitcher(duration: CircleMotion.fast, child: Icon(
          stats['liked'] == true || stats['mine'] == true
            ? Icons.favorite_rounded : Icons.favorite_border_rounded,
          key: ValueKey(stats['liked'] == true || stats['mine'] == true), size: 19)), label: Text('${stats['likes'] ?? 0}  Нравится')),
        TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CommentsScreen(api, id))), icon: const Icon(Icons.mode_comment_outlined, size: 19), label: Text('${stats['comments'] ?? 0}  Комментарии')),
        TextButton.icon(onPressed: () async {try {await api.call('post-repost', body: {'post_id': id}); if (context.mounted) refresh();} catch (error) {if (context.mounted) notify(context, '$error');}},
          icon: Icon(stats['reposted'] == true ? Icons.repeat : Icons.repeat, size: 19),
          label: Text('${stats['reposts'] ?? 0}  Репост')),
      ]),
    ]));
  }
}

class CommentsScreen extends StatefulWidget {
  const CommentsScreen(this.api, this.postId, {super.key});
  final CircleApi api;
  final int postId;
  @override State<CommentsScreen> createState() => _CommentsScreenState();
}
class _CommentsScreenState extends State<CommentsScreen> {
  final controller = TextEditingController();
  int? reply;
  int reload = 0;
  bool saving = false;
  @override void dispose() {controller.dispose(); super.dispose();}
  Future<void> send() async {
    final text = controller.text.trim();
    if (text.isEmpty || saving) return;
    setState(() => saving = true);
    try {
      await widget.api.call('post-comment', body: {'post_id': widget.postId, 'body': text, 'parent_comment_id': reply ?? 0});
      controller.clear();
      if (mounted) setState(() {reply = null; reload++;});
    } catch (e) {if (mounted) notify(context, '$e');}
    finally {if (mounted) setState(() => saving = false);}
  }
  @override Widget build(BuildContext context) => CirclePage(title: 'Комментарии', child: Column(children: [
    Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: 'post-comments', query: {'post_id': '${widget.postId}'}, emptyTitle: 'Пока никто не прокомментировал', itemBuilder: (context, comment, refresh) => CircleSurface(padding: const EdgeInsets.all(14), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CircleUserAvatar(api: widget.api, user: obj(comment['author']), radius: 18), const SizedBox(width: 11),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(label(obj(comment['author'])), style: const TextStyle(fontWeight: FontWeight.w700))), Text(circleDate(comment['created_at']), style: const TextStyle(color: circleMuted, fontSize: 11))]),
        if (comment['parent_comment_id'] != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('↳ Ответ на #${comment['parent_comment_id']}', style: const TextStyle(color: circleGold, fontSize: 11))),
        const SizedBox(height: 6), Text('${comment['body'] ?? ''}'),
        Row(children: [TextButton(onPressed: () => setState(() => reply = identifier(comment['id'])), child: const Text('Ответить')),
          if (comment['mine'] == true) TextButton.icon(
            onPressed: () async {
              final confirmed = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
                title: const Text('Удалить комментарий?'),
                actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')),
                  FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Удалить'))],
              ));
              if (confirmed != true) return;
              try {await widget.api.call('post-comment-delete', body: {'comment_id': identifier(comment['id'])});
                if (mounted) setState(() => reload++);
              } catch (error) {if (mounted) notify(context, '$error');}
            }, icon: const Icon(Icons.delete_outline, size: 15), label: const Text('Удалить')),
        ]),
      ])),
    ])))),
    if (reply != null) Padding(padding: const EdgeInsets.symmetric(horizontal: 18), child: Row(children: [Expanded(child: Text('Ответ на комментарий #$reply', style: const TextStyle(color: circleGold))), IconButton(onPressed: () => setState(() => reply = null), icon: const Icon(Icons.close))])),
    Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, border: Border(top: BorderSide(color: Theme.of(context).dividerColor))), child: Row(children: [
      Expanded(child: TextField(controller: controller, maxLines: 3, minLines: 1, maxLength: 1200, decoration: const InputDecoration(hintText: 'Написать комментарий...'))),
      const SizedBox(width: 10), IconButton(onPressed: saving ? null : send, tooltip: 'Отправить', icon: const Icon(Icons.send_rounded, color: circleGold)),
    ])),
  ]));
}

class StoriesStrip extends StatefulWidget {
  const StoriesStrip(this.api, {super.key});
  final CircleApi api;
  @override State<StoriesStrip> createState() => _StoriesStripState();
}
class _StoriesStripState extends State<StoriesStrip> {
  late Future<Map<String, dynamic>> future;
  @override void initState() {super.initState(); _load();}
  void _load() {future = widget.api.call('stories');}
  Future<void> add() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm']);
    if (picked == null || picked.files.single.path == null || !mounted) return;
    final caption = await compose(context, 'Подпись к истории', maxLength: 180);
    if (caption == null) return;
    try {await widget.api.upload('story-create', File(picked.files.single.path!), field: 'media', fields: {'caption': caption}); if (mounted) setState(_load);}
    catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) => ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8), children: [
    _storyButton(icon: Icons.add, title: 'Твоя история', onTap: add, isAdd: true),
    if (snapshot.hasData) for (final story in items(snapshot.data!)) _storyButton(user: obj(story['author']), title: label(obj(story['author'])), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => StoryViewer(widget.api, story)))),
    if (snapshot.hasError) Center(child: Text('Истории недоступны', style: Theme.of(context).textTheme.bodySmall)),
  ]));
  Widget _storyButton({Map<String, dynamic>? user, IconData? icon, required String title, required VoidCallback onTap, bool isAdd = false}) => SizedBox(width: 96, child: InkWell(onTap: onTap, borderRadius: BorderRadius.circular(16), child: Column(children: [
    Container(width: 73, height: 73, padding: const EdgeInsets.all(4), decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold, width: 1.8)), child: isAdd
      ? Container(decoration: BoxDecoration(shape: BoxShape.circle, color: circleGold.withValues(alpha: .12)), child: const Icon(Icons.add, color: circleGold, size: 28))
      : Center(child: CircleUserAvatar(api: widget.api, user: user ?? {}, radius: 31))),
    const SizedBox(height: 8), Text(title, overflow: TextOverflow.ellipsis, maxLines: 1, style: const TextStyle(fontSize: 11)),
  ])));
}
class StoryViewer extends StatelessWidget {
  const StoryViewer(this.api, this.story, {super.key});
  final CircleApi api;
  final Map<String, dynamic> story;
  @override Widget build(BuildContext context) => CirclePage(title: label(obj(story['author'])), child: Center(child: Column(children: [
    Expanded(child: Padding(padding: const EdgeInsets.all(18), child: CircleMedia(api: api, route: 'story-media', id: identifier(story['id']), mime: '${story['media_mime'] ?? ''}'))),
    Padding(padding: const EdgeInsets.all(22), child: Text('${story['caption'] ?? ''}', style: Theme.of(context).textTheme.titleMedium)),
  ])));
}

class ProfileScreen extends StatefulWidget {
  const ProfileScreen(this.api, {super.key});
  final CircleApi api;
  @override State<ProfileScreen> createState() => _ProfileScreenState();
}
class _ProfileScreenState extends State<ProfileScreen> {
  int avatarVersion = 0;
  String postTab = 'posts';
  late Future<Map<String, dynamic>> profile;
  @override void initState() {super.initState(); reload();}
  void reload() {profile = _readProfile();}
  Future<Map<String, dynamic>> _readProfile() async {
    try { return await widget.api.call('profile'); }
    on CircleError catch (error) {
      if (!error.message.contains('HTTP 500')) rethrow;
      // Servers still on the unpatched Mobile API may throw during optional
      // rewards/verification queries. Show account details instead of a blank UI.
      final minimal = await widget.api.call('me');
      return {'ok': true, 'user': minimal['user'], 'degraded': true};
    }
  }
  Future<void> edit(Map<String, dynamic> data) async {
    final person = obj(data['user']);
    if (!mounted) return;
    final name = await compose(context, 'Отображаемое имя', initial: label(person), maxLength: 60);
    if (!mounted || name == null || name.isEmpty) return;
    final bio = await compose(context, 'О себе', initial: '${data['bio'] ?? ''}', maxLength: 500);
    if (!mounted || bio == null) return;
    final status = await compose(context, 'Статус', initial: '${data['status_text'] ?? ''}', maxLength: 80);
    if (!mounted || status == null) return;
    final visibility = await showDialog<String>(context: context, builder: (dialog) => SimpleDialog(
      title: const Text('Кто видит мой профиль?'),
      children: [
        SimpleDialogOption(onPressed: () => Navigator.pop(dialog, 'PUBLIC'), child: const Text('Все пользователи')),
        SimpleDialogOption(onPressed: () => Navigator.pop(dialog, 'MEMBERS'), child: const Text('Друзья')),
        SimpleDialogOption(onPressed: () => Navigator.pop(dialog, 'PRIVATE'), child: const Text('Приватный профиль')),
      ],
    ));
    if (visibility == null) return;
    try {
      await widget.api.call('profile-save', body: {'display_name': name, 'bio': bio, 'status_text': status, 'visibility': visibility});
      if (mounted) setState(reload);
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> uploadAvatar() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
    if (picked?.files.single.path == null) return;
    try {
      await widget.api.upload('avatar-upload', File(picked!.files.single.path!), field: 'avatar');
      widget.api.clearMedia('avatar');
      if (mounted) setState(() {avatarVersion++; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> uploadCover() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
    if (picked?.files.single.path == null) return;
    try {
      await widget.api.upload('profile-cover-upload', File(picked!.files.single.path!), field: 'cover');
      widget.api.clearMedia('profile-cover');
      if (mounted) setState(() {avatarVersion++; reload();});
    } catch (error) {if (mounted) notify(context, '$error');}
  }
  @override Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(future: profile, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Профиль не загрузился', description: '${snapshot.error}', action: OutlinedButton(onPressed: () => setState(reload), child: const Text('Повторить')));
    if (!snapshot.hasData) return const CircleLoadingState();
    final data = snapshot.data!;
    final person = obj(data['user']);
    final counts = obj(data['counts']);
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1030), child: ListView(padding: const EdgeInsets.fromLTRB(24, 26, 24, 35), children: [
      if (data['degraded'] == true) Padding(padding: const EdgeInsets.only(bottom: 16), child: CircleSurface(accent: true, child: const Text('Профиль открыт в ограниченном режиме: серверный Mobile API требует совместимого исправления. Данные аккаунта сохранены.', style: TextStyle(color: circleGoldBright)))),
      CircleSurface(padding: EdgeInsets.zero, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 195, decoration: BoxDecoration(borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [const Color(0xFF282521), circleGold.withValues(alpha: .22), const Color(0xFF141519)])),
          child: Stack(children: [
            if (data['cover_url'] != null) Positioned.fill(child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(18)), child: CircleRemoteImage(key: ValueKey(avatarVersion), api: widget.api, route: 'profile-cover', id: identifier(person['id'])))),
            Positioned(right: 30, top: -58, child: Container(width: 320, height: 320, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold.withValues(alpha: .15), width: 2)))),
            Positioned(right: 75, top: -15, child: Container(width: 235, height: 235, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold.withValues(alpha: .23))))),
            const Positioned(bottom: 28, left: 28, child: Text('МОЙ ПРОФИЛЬ', style: TextStyle(letterSpacing: 3, color: circleGoldBright, fontWeight: FontWeight.w700, fontSize: 11))),
            Positioned(bottom: 16, right: 18, child: OutlinedButton.icon(onPressed: uploadCover,
              icon: const Icon(Icons.wallpaper_rounded, size: 17), label: const Text('Изменить обложку'))),
          ])),
        Padding(padding: const EdgeInsets.fromLTRB(26, 0, 26, 25), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Transform.translate(offset: const Offset(0, -33), child: Wrap(spacing: 12, runSpacing: 9,
            crossAxisAlignment: WrapCrossAlignment.end, children: [
            GestureDetector(onTap: uploadAvatar, child: CircleUserAvatar(key: ValueKey(avatarVersion), api: widget.api, user: person, radius: 49)),
            OutlinedButton.icon(onPressed: uploadAvatar, icon: const Icon(Icons.photo_camera_outlined, size: 17), label: const Text('Аватар')),
            OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RewardSettingsScreen(widget.api))), icon: const Icon(Icons.workspace_premium_outlined, size: 17), label: const Text('Награды')),
            FilledButton.icon(onPressed: () => edit(data), icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('Изменить профиль')),
          ])),
          Transform.translate(offset: const Offset(0, -18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Flexible(child: Text(label(person), style: Theme.of(context).textTheme.headlineMedium)), if (person['verified'] == true) const Padding(padding: EdgeInsets.only(left: 7), child: Icon(Icons.verified, color: circleGold))]),
            const SizedBox(height: 5), Text('@${person['username'] ?? ''}', style: const TextStyle(color: circleGoldBright, fontSize: 13)),
            if ('${data['status_text'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 11), child: Text('${data['status_text']}', style: const TextStyle(fontWeight: FontWeight.w600))),
            if ('${data['bio'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text('${data['bio']}')),
          ])),
          const SizedBox(height: 6), Divider(color: Theme.of(context).dividerColor),
          Wrap(spacing: 12, runSpacing: 12, children: [
            CircleProfileMetric(icon: Icons.people_outline_rounded,
              value: '${counts['friends'] ?? person['friends_count'] ?? '—'}', label: 'Друзья'),
            CircleProfileMetric(icon: Icons.article_outlined,
              value: '${counts['posts'] ?? person['posts_count'] ?? '—'}', label: 'Публикации'),
            CircleProfileMetric(icon: Icons.groups_2_outlined,
              value: '${counts['communities'] ?? person['communities_count'] ?? '—'}', label: 'Сообщества'),
          ]),
        ])),
      ])),
      const SizedBox(height: 23), const CircleSection(title: 'Публикации', subtitle: 'Мои записи, фотографии и репосты'),
      const SizedBox(height: 14), Align(alignment: Alignment.centerLeft, child: SegmentedButton<String>(segments: const [
          ButtonSegment(value: 'posts', label: Text('Мои записи'), icon: Icon(Icons.article_outlined)),
          ButtonSegment(value: 'reposts', label: Text('Репосты'), icon: Icon(Icons.repeat)),
        ], selected: {postTab}, onSelectionChanged: (selected) => setState(() => postTab = selected.first))),
      const SizedBox(height: 16), SizedBox(height: 680, child: FeedScreen(widget.api,
        key: ValueKey('profile-$postTab'), route: 'profile-posts', query: {'tab': postTab})),
    ])));
  });
}

/// Native friends, requests and people search. These routes ship in the
/// companion Mobile API 5.2.3 compatibility patch, not in the old server.
class FriendsScreen extends StatefulWidget {
  const FriendsScreen(this.api, {super.key});
  final CircleApi api;
  @override State<FriendsScreen> createState() => _FriendsScreenState();
}
class _FriendsScreenState extends State<FriendsScreen> {
  int tab = 0;
  int revision = 0;
  final search = TextEditingController();
  Timer? searchDebounce;
  String term = '';
  @override void dispose() {searchDebounce?.cancel(); search.dispose(); super.dispose();}

  Future<void> act(String route, Map<String, dynamic> body) async {
    try {
      await widget.api.call(route, body: body);
      if (mounted) {setState(() => revision++); notify(context, 'Изменения сохранены');}
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  void view(Map<String, dynamic> person) {
    Navigator.push(context, MaterialPageRoute<void>(
      builder: (_) => PublicProfile(widget.api, identifier(person['id']))));
  }
  Widget personTile(Map<String, dynamic> person, {Widget? action}) => CircleSurface(
    padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 14),
    child: Row(children: [CircleUserAvatar(api: widget.api, user: person, radius: 24),
      const SizedBox(width: 14), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label(person), overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium),
        const SizedBox(height: 3), Text('@${person['username'] ?? ''}',
          overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall),
      ])),
      if (action != null) action,
      IconButton(tooltip: 'Открыть профиль', icon: const Icon(Icons.chevron_right_rounded),
        onPressed: () => view(person)),
    ]));
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 1080),
    child: Column(children: [
      const Padding(padding: EdgeInsets.fromLTRB(24, 27, 24, 17), child: CircleSection(
        title: 'Друзья', subtitle: 'Знакомые, заявки и поиск людей в твоём круге')),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Row(children: [
        for (final item in [(0, 'Мои друзья', Icons.people_alt_outlined),
          (1, 'Заявки', Icons.person_add_alt_1_outlined),
          (2, 'Найти людей', Icons.search_rounded)])
          Padding(padding: const EdgeInsets.only(right: 9), child: ChoiceChip(
            label: Text(item.$2), avatar: Icon(item.$3, size: 17,
              color: tab == item.$1 ? circleGoldBright : circleMuted),
            selected: tab == item.$1, onSelected: (_) => setState(() => tab = item.$1))),
      ])),
      if (tab == 2) Padding(padding: const EdgeInsets.fromLTRB(24, 14, 24, 4), child: TextField(
        controller: search, decoration: const InputDecoration(
          hintText: 'Имя или никнейм (от 2 символов)', prefixIcon: Icon(Icons.search_rounded)),
        onChanged: (value) {
          searchDebounce?.cancel();
          searchDebounce = Timer(const Duration(milliseconds: 350), () {
            if (mounted) setState(() => term = value.trim());
          });
        },
      )),
      const SizedBox(height: 12),
      Expanded(child: tab == 0
        ? ApiList(key: ValueKey('friends-$revision'), api: widget.api,
            route: 'friends', emptyTitle: 'В твоём круге пока нет друзей',
            itemBuilder: (context, person, refresh) => personTile(person, action: PopupMenuButton<String>(
              tooltip: 'Действия', icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (command) {if (command == 'remove') act('friend-remove', {'user_id': identifier(person['id'])});},
              itemBuilder: (_) => const [PopupMenuItem(value: 'remove', child: Text('Убрать из друзей'))])))
        : tab == 1
        ? ApiList(key: ValueKey('requests-$revision'), api: widget.api,
            route: 'friend-requests', emptyTitle: 'Нет новых заявок',
            itemBuilder: (context, request, refresh) {
              final person = obj(request['person']);
              final id = identifier(request['friendship_id']);
              final incoming = request['direction'] == 'incoming';
              return personTile(person, action: Wrap(spacing: 6, children: incoming ? [
                OutlinedButton(onPressed: () => act('friend-respond',
                    {'friendship_id': id, 'decision': 'DECLINED'}), child: const Text('Отклонить')),
                FilledButton(onPressed: () => act('friend-respond',
                    {'friendship_id': id, 'decision': 'ACCEPTED'}), child: const Text('Принять')),
              ] : [TextButton(onPressed: () => act('friend-request-cancel',
                  {'friendship_id': id}), child: const Text('Отменить заявку'))]));
            })
        : term.length < 2
        ? const CircleEmpty(title: 'Найди своих людей',
            description: 'Введи имя или никнейм, чтобы найти пользователей Circle.',
            icon: Icons.search_rounded)
        : ApiList(key: ValueKey('people-$revision-$term'), api: widget.api,
            route: 'people-search', query: {'q': term},
            emptyTitle: 'Ничего не найдено',
            itemBuilder: (context, person, refresh) => personTile(person,
              action: OutlinedButton.icon(onPressed: () => act('friend-request',
                  {'user_id': identifier(person['id'])}),
                icon: const Icon(Icons.person_add_alt_1, size: 17),
                label: const Text('Добавить'))))),
    ])));
}

class PublicProfile extends StatefulWidget {
  const PublicProfile(this.api, this.id, {super.key});
  final CircleApi api;
  final int id;
  @override State<PublicProfile> createState() => _PublicProfileState();
}
class _PublicProfileState extends State<PublicProfile> {
  late Future<Map<String, dynamic>> request;
  Future<void> openConversation(Map<String, dynamic> peer) async {
    try {
      final conversation = await widget.api.call('dm-open', body: {'user_id': widget.id});
      final current = await widget.api.call('me');
      if (!mounted) return;
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => MessagesScreen(
        widget.api, identifier(conversation['conversation_id']), peer: peer, me: obj(current['user']))));
    } catch (error) {if (mounted) notify(context, '$error');}
  }
  @override void initState() {super.initState(); request = widget.api.call('user-profile', query: {'id': '${widget.id}'});}
  @override void didUpdateWidget(covariant PublicProfile old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.api != widget.api) {
      request = widget.api.call('user-profile', query: {'id': '${widget.id}'});
    }
  }
  @override Widget build(BuildContext context) => CirclePage(title: 'Профиль', child: FutureBuilder<Map<String, dynamic>>(
    future: request,
    builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Профиль недоступен', description: '${snapshot.error}');
      if (!snapshot.hasData) return const CircleLoadingState();
      final data = snapshot.data!;
      final person = obj(data['user']);
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: Column(children: [
        Padding(padding: const EdgeInsets.all(24), child: CircleSurface(child: Row(children: [CircleUserAvatar(api: widget.api, user: person, radius: 39), const SizedBox(width: 19), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(person), style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 4), Text('@${person['username'] ?? ''}', style: const TextStyle(color: circleGoldBright)),
          const SizedBox(height: 10), OutlinedButton.icon(onPressed: () => openConversation(person),
            icon: const Icon(Icons.chat_bubble_outline_rounded, size: 16), label: const Text('Написать сообщение')),
          if ('${data['bio'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 11), child: Text('${data['bio']}'))]))]))),
        Expanded(child: FeedScreen(widget.api, route: 'profile-posts', query: {'user_id': '${widget.id}'})),
      ])));
    },
  ));
}

class MessengerScreen extends StatefulWidget {
  const MessengerScreen(this.api, {super.key, required this.me});
  final CircleApi api;
  final Map<String, dynamic> me;
  @override State<MessengerScreen> createState() => _MessengerScreenState();
}
class _MessengerScreenState extends State<MessengerScreen> {
  late Future<List<Map<String, dynamic>>> conversations;
  Map<String, dynamic>? selected;
  GlobalKey<_MessagesScreenState> activeConversationKey = GlobalKey<_MessagesScreenState>();
  @override void initState() {super.initState(); reload();}
  void reload() {conversations = widget.api.call('desktop-conversations').then(items);}
  Future<void> openSavedMessages() async {
    try {
      final result = await widget.api.call('desktop-saved-chat', body: {});
      if (!mounted) return;
      final conversationId = identifier(result['conversation_id']);
      if (conversationId < 1) return;
      final savedConversation = <String, dynamic>{
        'id': conversationId,
        'peer': <String, dynamic>{'id': 0, 'username': 'saved',
          'display_name': 'Избранное'},
        'saved': true,
      };
      _openConversation(savedConversation);
      setState(reload);
    } catch (error) { if (mounted) notify(context, '$error'); }
  }

  void _openConversation(Map<String, dynamic> conversation) {
    setState(() {
      if (identifier(selected?['id']) != identifier(conversation['id'])) {
        activeConversationKey = GlobalKey<_MessagesScreenState>();
      }
      selected = conversation;
    });
  }

  void _closeConversation() {
    setState(() {selected = null; reload();});
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(builder: (context, constraints) {
    final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
    final singlePane = constraints.maxWidth < 940 + (textScale - 1).clamp(0, 1) * 240;
    final compact = constraints.maxWidth < 1090;
    final listPane = Column(children: [
      Container(constraints: const BoxConstraints(minHeight: 75), padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
        child: Row(children: [
          Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text('Сообщения', maxLines: 1, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleLarge),
              const SizedBox(height: 5),
              const Text('Личные переписки', style: TextStyle(color: circleMuted, fontSize: 11)),
            ])),
          CircleIconAction(tooltip: 'Архив', icon: Icons.archive_outlined,
            onPressed: () => Navigator.push(context, MaterialPageRoute<void>(
              builder: (_) => DesktopArchiveScreen(widget.api)))),
          const SizedBox(width: 6),
          CircleIconAction(tooltip: 'Избранное', icon: Icons.bookmark_outline_rounded,
            onPressed: openSavedMessages),
        ])),
      Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(
        future: conversations, builder: (context, snapshot) {
          if (snapshot.hasError) return CircleEmpty(title: 'Нет соединения',
            description: '${snapshot.error}', action: TextButton(
              onPressed: () => setState(reload), child: const Text('Повторить')));
          if (!snapshot.hasData) return const CircleLoadingState();
          final data = snapshot.data!;
          if (data.isEmpty) return const CircleEmpty(title: 'Нет диалогов',
            icon: Icons.forum_outlined);
          return ListView.builder(
            padding: const EdgeInsets.symmetric(vertical: 9),
            itemCount: data.length, cacheExtent: 350,
            itemBuilder: (context, index) {
              final conversation = data[index];
              return CircleConversationTile(
                key: ValueKey(identifier(conversation['id'])),
                api: widget.api, conversation: conversation,
                active: identifier(selected?['id']) ==
                  identifier(conversation['id']),
                onTap: () => _openConversation(conversation),
              );
            },
          );
        })),
    ]);
    return Row(children: [
      if (singlePane && selected == null) Expanded(child: listPane),
      if (!singlePane) ...[
        SizedBox(width: compact ? 270 : 325, child: listPane),
        Container(width: 1, color: Theme.of(context).dividerColor),
      ],
      if (!singlePane || selected != null)
        Expanded(child: selected == null
          ? const CircleEmpty(title: 'Выберите диалог',
              description: 'Все ваши разговоры — в одном месте.',
              icon: Icons.forum_outlined)
          : MessagesScreen(widget.api, identifier(selected!['id']),
              key: activeConversationKey,
              peer: obj(selected!['peer']), me: widget.me, embedded: true,
              onBack: singlePane ? _closeConversation : null)),
    ]);
  });
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen(this.api, this.id, {super.key, required this.peer, required this.me, this.embedded = false, this.onBack});
  final CircleApi api;
  final int id;
  final Map<String, dynamic> peer;
  final Map<String, dynamic> me;
  final bool embedded;
  final VoidCallback? onBack;
  @override State<MessagesScreen> createState() => _MessagesScreenState();
}
class _MessagesScreenState extends State<MessagesScreen> {
  final input = TextEditingController();
  int? reply;
  late Future<List<Map<String, dynamic>>> messages;
  bool sending = false;
  bool recording = false;
  bool startingCall = false;
  Timer? messagePoll;
  bool messagePollBusy = false;
  String lastMessageDigest = '';
  int requestGeneration = 0;
  AudioRecorder? recorder;
  AudioRecorder get voiceRecorder => recorder ??= AudioRecorder();
  @override void initState() {
    super.initState();
    reload();
    messagePoll = Timer.periodic(const Duration(seconds: 7), (_) => refreshMessagesSilently());
  }
  @override void didUpdateWidget(covariant MessagesScreen old) {
    super.didUpdateWidget(old);
    if (old.id != widget.id || old.api != widget.api) {
      input.clear(); reply = null; reload();
    }
  }
  void reload() {
    requestGeneration++;
    lastMessageDigest = '';
    messages = widget.api.call('messages', query: {'conversation_id': '${widget.id}'}).then(items);
  }
  Future<void> refreshMessagesSilently() async {
    if (messagePollBusy || !mounted || !TickerMode.of(context) ||
        WidgetsBinding.instance.lifecycleState != AppLifecycleState.resumed) return;
    messagePollBusy = true;
    final generation = requestGeneration;
    final conversationId = widget.id;
    final client = widget.api;
    try {
      final latest = items(await client.call('messages',
        query: {'conversation_id': '$conversationId'}));
      final last = latest.isEmpty ? 0 : identifier(latest.last['id']);
      // Edits, reactions and attachments can change without creating a new
      // message ID. Keep a small tail fingerprint rather than re-rendering
      // every time the poll returns an identical batch.
      final tail = latest.length > 5 ? latest.sublist(latest.length - 5) : latest;
      final digest = '$conversationId:${latest.length}:$last:${jsonEncode(tail)}';
      if (mounted && generation == requestGeneration &&
          conversationId == widget.id && client == widget.api && digest != lastMessageDigest) {
        setState(() {lastMessageDigest = digest; messages = Future.value(latest);});
      }
    } catch (_) { // Background polling must never interrupt typing.
    } finally {messagePollBusy = false;}
  }
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    final conversationId = widget.id;
    final client = widget.api;
    try {
      await client.call('messages', query: {'conversation_id': '$conversationId'}, body: {'body': text, 'reply_to_id': reply ?? 0});
      if (!mounted || conversationId != widget.id || client != widget.api) return;
      input.clear();
      if (mounted) setState(() {reply = null; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
    finally {if (mounted) setState(() => sending = false);}
  }
  Future<void> attach({bool voice = false}) async {
    final conversationId = widget.id;
    final replyId = reply;
    final client = widget.api;
    final chosen = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: voice ? ['ogg', 'webm', 'mp3', 'wav', 'm4a'] : ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm']);
    if (!mounted || conversationId != widget.id || client != widget.api || chosen?.files.single.path == null) return;
    try {
      await client.upload('message-upload', File(chosen!.files.single.path!), query: {'conversation_id': '$conversationId'}, fields: {'kind': voice ? 'VOICE' : 'FILE', 'reply_to_id': '${replyId ?? 0}'});
      if (mounted && conversationId == widget.id && client == widget.api) setState(() {reply = null; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> react(int id, String value) async {
    try {
      await widget.api.call('message-reaction', body: {'conversation_id': widget.id, 'message_id': id, 'emoji': value});
      if (mounted) setState(reload);
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> startCall({bool video = false}) async {
    if (startingCall) return;
    startingCall = true;
    final client = widget.api;
    final conversationId = widget.id;
    final peerName = label(widget.peer);
    try {
      final started = await client.call('mobile-call-start', body: {'conversation_id': conversationId});
      final callId = identifier(started['call_id']);
      if (callId < 1) return;
      if (!mounted || conversationId != widget.id || client != widget.api) {
        await client.call('mobile-call-finish', body: {'conversation_id': conversationId, 'call_id': callId});
        return;
      }
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CircleLiveRoom(
        title: 'Звонок · $peerName', startVideo: video,
        credentials: () => client.call('mobile-call-token', body: {'conversation_id': conversationId, 'call_id': callId}),
        onFinish: () => client.call('mobile-call-finish', body: {'conversation_id': conversationId, 'call_id': callId}).then((_) {}),
      )));
    } catch (e) {if (mounted) notify(context, 'Звонок недоступен: $e');}
    finally {startingCall = false;}
  }
  Future<void> toggleRecording() async {
    if (recording) {
      try {
        final path = await voiceRecorder.stop();
        if (mounted) setState(() => recording = false);
        if (!mounted || path == null) return;
        final file = File(path);
        if (await file.exists()) {
          final size = await file.length();
          if (size > 30 * 1024 * 1024) {
            if (mounted) notify(context, 'Запись превышает ограничение сервера в 30 МБ');
            return;
          }
          await widget.api.upload('message-upload', file, query: {'conversation_id': '${widget.id}'}, fields: {'kind': 'VOICE', 'reply_to_id': '${reply ?? 0}'});
          if (mounted) setState(() {reply = null; reload();});
          try {await file.delete();} catch (_) { /* Cache cleanup only. */ }
        }
      } catch (e) {if (mounted) notify(context, 'Ошибка голосового сообщения: $e');}
      return;
    }
    try {
      final allowed = await voiceRecorder.hasPermission();
      if (!mounted) return;
      if (!allowed) {if (mounted) notify(context, 'Разрешите доступ к микрофону в настройках Windows'); return;}
      final folder = await getTemporaryDirectory();
      if (!mounted) return;
      final file = '${folder.path}${Platform.pathSeparator}circle_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      await voiceRecorder.start(const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1, sampleRate: 16000), path: file);
      if (mounted) setState(() => recording = true);
    } catch (e) {if (mounted) notify(context, 'Не удалось включить микрофон: $e');}
  }
  @override void dispose() {
    messagePoll?.cancel();
    final activeRecorder = recorder;
    if (activeRecorder != null) {
      unawaited(_releaseRecorder(activeRecorder, recording));
    }
    input.dispose(); super.dispose();
  }
  Future<void> _releaseRecorder(AudioRecorder activeRecorder, bool wasRecording) async {
    try {
      try {
        if (wasRecording) await activeRecorder.stop();
      } finally {await activeRecorder.dispose();}
    } catch (error, stack) {
      CircleStartupLog.report('voice recorder cleanup', error, stack);
    }
  }
  @override Widget build(BuildContext context) {
    final chat = LayoutBuilder(builder: (context, constraints) {
      final textScale = MediaQuery.textScalerOf(context).scale(16) / 16;
      final compact = constraints.maxWidth < 660 ||
          (textScale > 1.2 && constraints.maxWidth < 850);
      return Column(children: [
      _conversationHeader(compact),
      Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: messages, builder: (context, snapshot) {
        if (snapshot.hasError) return CircleEmpty(title: 'Сообщения не загрузились', description: '${snapshot.error}', action: TextButton(onPressed: () => setState(reload), child: const Text('Повторить')));
        if (!snapshot.hasData) return const CircleLoadingState();
        if (snapshot.data!.isEmpty) return const CircleEmpty(title: 'Начните разговор', description: 'Напишите первое сообщение', icon: Icons.chat_bubble_outline);
        final data = snapshot.data!;
        return ListView.builder(key: PageStorageKey('dm-messages-${widget.id}'),
          padding: EdgeInsets.symmetric(horizontal: compact ? 12 : 22, vertical: 20),
          reverse: true, itemCount: data.length, cacheExtent: 320,
          itemBuilder: (context, index) => _messageBubble(data[data.length - 1 - index]));
      })),
      if (recording) Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7), color: circleRed.withValues(alpha: .15), child: const Row(children: [Icon(Icons.fiber_manual_record, size: 14, color: circleRed), SizedBox(width: 8), Expanded(child: Text('Идёт запись — нажмите на микрофон, чтобы отправить', style: TextStyle(color: circleRed, fontSize: 12)))])),
      if (reply != null) Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), color: circleGold.withValues(alpha: .08), child: Row(children: [const Icon(Icons.reply, color: circleGold, size: 17), const SizedBox(width: 7), Expanded(child: Text('Ответ на сообщение #$reply', style: const TextStyle(fontSize: 12))), IconButton(onPressed: () => setState(() => reply = null), icon: const Icon(Icons.close, size: 18))])),
      _composer(compact),
    ]);
    });
    return widget.embedded ? chat : CirclePage(title: label(widget.peer), child: chat);
  }

  Future<void> _archive() async {
    try {
      await widget.api.call('desktop-dm-archive', body: {'conversation_id': widget.id, 'archived': true});
      if (mounted) fxNotice(context, 'Диалог перемещён в архив');
    } catch (e) {if (mounted) fxNotice(context, e);}
  }

  Widget _conversationHeader(bool compact) => Container(
    constraints: const BoxConstraints(minHeight: 75),
    padding: EdgeInsets.symmetric(horizontal: compact ? 10 : 20, vertical: 12),
    decoration: BoxDecoration(color: Theme.of(context).cardTheme.color,
      border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
    child: Row(children: [
      if (widget.onBack != null) ...[
        IconButton(tooltip: 'К списку диалогов', onPressed: widget.onBack,
          icon: const Icon(Icons.arrow_back_rounded)),
        const SizedBox(width: 4),
      ],
      CircleUserAvatar(api: widget.api, user: widget.peer, radius: 20),
      const SizedBox(width: 12),
      Expanded(child: Column(mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label(widget.peer), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.titleMedium),
        Text(identifier(widget.peer['id']) == 0 ? 'Только ты видишь эти сообщения' : '@${widget.peer['username'] ?? ''}',
          maxLines: 1, overflow: TextOverflow.ellipsis,
          style: Theme.of(context).textTheme.bodySmall),
      ])),
      if (compact) PopupMenuButton<String>(
        tooltip: 'Действия с диалогом', icon: const Icon(Icons.more_horiz_rounded),
        onSelected: (action) {
          if (action == 'call') startCall();
          if (action == 'video') startCall(video: true);
          if (action == 'archive') _archive();
          if (action == 'refresh') setState(reload);
        },
        itemBuilder: (_) => [
          if (identifier(widget.peer['id']) > 0) ...[
            const PopupMenuItem(value: 'call', child: Text('Голосовой звонок')),
            const PopupMenuItem(value: 'video', child: Text('Видеозвонок')),
          ],
          const PopupMenuItem(value: 'archive', child: Text('В архив')),
          const PopupMenuItem(value: 'refresh', child: Text('Обновить сообщения')),
        ],
      ) else ...[
        if (identifier(widget.peer['id']) > 0) ...[
          IconButton(tooltip: 'Голосовой звонок', onPressed: () => startCall(), icon: const Icon(Icons.call_outlined, color: circleGold)),
          IconButton(tooltip: 'Видеозвонок', onPressed: () => startCall(video: true), icon: const Icon(Icons.videocam_outlined, color: circleGold)),
        ],
        IconButton(tooltip: 'В архив', onPressed: _archive, icon: const Icon(Icons.archive_outlined)),
        IconButton(tooltip: 'Обновить сообщения', onPressed: () => setState(reload), icon: const Icon(Icons.refresh_rounded)),
      ],
    ]),
  );

  Widget _composer(bool compact) {
    final attachments = <Widget>[
      IconButton(tooltip: 'Прикрепить фото / видео', onPressed: () => attach(), icon: const Icon(Icons.attach_file, color: circleGold)),
      IconButton(tooltip: recording ? 'Остановить и отправить голосовое сообщение' : 'Записать голосовое сообщение', onPressed: toggleRecording, icon: Icon(recording ? Icons.stop_circle_outlined : Icons.mic_none_outlined, color: recording ? circleRed : circleGold)),
      IconButton(tooltip: 'Прикрепить аудиофайл', onPressed: () => attach(voice: true), icon: const Icon(Icons.audio_file_outlined, color: circleGold)),
    ];
    final field = TextField(controller: input, minLines: 1, maxLines: 4,
      maxLength: 10000, onSubmitted: (_) => send(),
      decoration: const InputDecoration(hintText: 'Написать сообщение...', counterText: ''));
    final submit = Tooltip(message: 'Отправить сообщение', child: CircleAccentButton(
      label: '', icon: Icons.send_rounded, compact: true,
      busy: sending, onPressed: sending ? null : send));
    return Container(padding: EdgeInsets.all(compact ? 10 : 15),
      decoration: BoxDecoration(color: Theme.of(context).cardTheme.color,
        border: Border(top: BorderSide(color: Theme.of(context).dividerColor))),
      child: compact ? Column(mainAxisSize: MainAxisSize.min, children: [
        Row(children: [Expanded(child: field), const SizedBox(width: 9), submit]),
        const SizedBox(height: 4),
        Align(alignment: Alignment.centerLeft, child: Wrap(children: attachments)),
      ]) : Row(children: [
        ...attachments, const SizedBox(width: 7), Expanded(child: field),
        const SizedBox(width: 9), submit,
      ]),
    );
  }
  Widget _messageBubble(Map<String, dynamic> message) {
    final mine = identifier(message['user_id']) == identifier(widget.me['id']);
    final attachments = (message['attachments'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final id = identifier(message['id']);
    return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: Padding(padding: const EdgeInsets.only(bottom: 12), child: CircleMessageShell(mine: mine,
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (message['reply_to_id'] != null) Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: circleGold.withValues(alpha: .08), borderRadius: BorderRadius.circular(7)), child: Text('↳ ${message['reply_body'] ?? 'Ответ на сообщение'}', style: const TextStyle(color: circleGoldBright, fontSize: 12), maxLines: 3)),
        if ('${message['body'] ?? ''}'.isNotEmpty) SelectableText('${message['body']}', style: const TextStyle(fontSize: 13.5, height: 1.5)),
        for (final attachment in attachments) Padding(padding: const EdgeInsets.only(top: 10), child: CircleMedia(api: widget.api, route: 'attachment', id: identifier(attachment['id']), mime: '${attachment['mime'] ?? ''}', compact: true)),
        Row(mainAxisSize: MainAxisSize.min, children: [Text(circleDate(message['created_at']), style: const TextStyle(color: circleMuted, fontSize: 10)), const SizedBox(width: 9), PopupMenuButton<String>(tooltip: 'Действия с сообщением', icon: const Icon(Icons.more_horiz, size: 18), padding: EdgeInsets.zero,
          onSelected: (value) async {
            if(value == 'reply') {setState(() => reply = id); return;}
            if(value == 'edit') {final body = await fxPrompt(context, 'Изменить сообщение', initial: '${message['body'] ?? ''}', lines: 4);if(!mounted||body==null)return;try{await widget.api.call('desktop-dm-edit',body:{'conversation_id':widget.id,'message_id':id,'body':body});if(mounted)setState(reload);}catch(e){if(mounted)fxNotice(context,e);}return;}
            if(value == 'delete') {if(!await fxConfirm(context,'Удалить сообщение?', 'Это действие нельзя отменить.'))return;try{await widget.api.call('desktop-dm-delete',body:{'conversation_id':widget.id,'message_id':id});if(mounted)setState(reload);}catch(e){if(mounted)fxNotice(context,e);}return;}
            if (value == 'report') {
              final reason = await fxPrompt(context, 'Причина жалобы на сообщение', lines: 3);
              if (!mounted || reason == null) return;
              if (reason.trim().length < 5) {
                fxNotice(context, 'Укажи причину хотя бы в 5 символах');
                return;
              }
              try {
                await widget.api.call('desktop-dm-report', body: {
                  'message_id': id, 'reason': reason.trim(),
                });
                if (mounted) fxNotice(context, 'Жалоба отправлена на проверку');
              } catch (error) { if (mounted) fxNotice(context, error); }
              return;
            }
            react(id,value);
          },
          itemBuilder: (_) => [const PopupMenuItem(value: 'reply', child: Text('Ответить')), if(mine)const PopupMenuItem(value:'edit',child: Text('Изменить')), if(mine)const PopupMenuItem(value:'delete',child:Text('Удалить')),
            if (!mine) const PopupMenuItem(value:'report',child: Text('Пожаловаться')),
            ...['❤️', '👍', '😂', '🔥', '👏'].map((reaction) => PopupMenuItem(value: reaction, child: Text(reaction)))],
        )]),
      ]),
    ))));
  }
}

class CommunitiesScreen extends StatefulWidget {
  const CommunitiesScreen(this.api, {super.key});
  final CircleApi api;
  @override State<CommunitiesScreen> createState() => _CommunitiesScreenState();
}
class _CommunitiesScreenState extends State<CommunitiesScreen> {
  int reload = 0;
  Future<void> join() async {
    final raw = await compose(context, 'Код приглашения', maxLength: 1000);
    if (!mounted || raw == null || raw.isEmpty) return;
    final match = RegExp(r'([a-fA-F0-9]{48})').firstMatch(raw);
    if (match == null) {notify(context, 'Нужен действительный код приглашения из 48 символов'); return;}
    final token = match.group(1)!.toLowerCase();
    try {
      final preview = await widget.api.call('invite-preview', query: {'token': token});
      if (!mounted) return;
      final c = obj(preview['community']);
      final yes = await showDialog<bool>(context: context, builder: (d) => AlertDialog(
        title: Text('Вступить в «${c['name'] ?? 'сообщество'}»?'),
        content: Text('${c['description'] ?? ''}'),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Отмена')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Вступить'))],
      ));
      if (yes != true) return;
      await widget.api.call('invite-join', body: {'token': token});
      if (mounted) {notify(context, 'Вы вступили в сообщество'); setState(() => reload++);}
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1050), child: Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(24, 26, 24, 18), child: CircleSection(title: 'Мои сообщества', subtitle: 'Пространства, в которые тебя пригласили', trailing: Wrap(spacing: 8, runSpacing: 8, children: [OutlinedButton.icon(onPressed: () async {final made = await Navigator.push<bool>(context, MaterialPageRoute(builder: (_) => DesktopCreateCommunity(widget.api))); if (made == true && mounted) setState(() => reload++);}, icon: const Icon(Icons.add), label: const Text('Создать')), CircleAccentButton(label: 'По приглашению', icon: Icons.link_rounded, onPressed: join)]))),
    Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: 'communities', emptyTitle: 'Ты пока не состоишь в сообществах', itemBuilder: (context, item, refresh) => CircleSurface(child: Row(children: [
      Container(width: 58, height: 58, decoration: BoxDecoration(color: circleGold.withValues(alpha: .13), borderRadius: BorderRadius.circular(13)), child: const Icon(Icons.groups_2_outlined, color: circleGold, size: 28)),
      const SizedBox(width: 17), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${item['name'] ?? ''}', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 4), Text('${item['description'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.bodySmall), const SizedBox(height: 7), Text('${item['members'] ?? '—'} участников', style: const TextStyle(fontSize: 11, color: circleGold))])),
      OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CommunityScreen(widget.api, identifier(item['id'])))), icon: const Icon(Icons.arrow_forward_rounded, size: 16), label: const Text('Открыть')),
    ])))),
  ])));
}
class CommunityScreen extends StatefulWidget {
  const CommunityScreen(this.api, this.id, {super.key});
  final CircleApi api;
  final int id;
  @override State<CommunityScreen> createState() => _CommunityScreenState();
}
class _CommunityScreenState extends State<CommunityScreen> {
  late Future<Map<String, dynamic>> future;
  @override void initState() {super.initState(); reload();}
  void reload() {future = widget.api.call('community', query: {'id': '${widget.id}'});}
  Future<void> publish() async {
    final title = await compose(context, 'Заголовок новости', maxLength: 140);
    if (!mounted || title == null || title.isEmpty) return;
    final content = await compose(context, 'Текст новости', maxLength: 4000);
    if (!mounted || content == null) return;
    try {await widget.api.call('community-post-create', body: {'community_id': widget.id, 'title': title, 'body': content}); if (mounted) {notify(context, 'Новость опубликована'); setState(reload);}}
    catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> manage(Map<String, dynamic> item) async {
    final name = await compose(context, 'Название сообщества', initial: '${item['name'] ?? ''}', maxLength: 80);
    if (!mounted || name == null || name.length < 2) return;
    final desc = await compose(context, 'Описание сообщества', initial: '${item['description'] ?? ''}', maxLength: 500);
    if (!mounted || desc == null) return;
    try {await widget.api.call('community-manage', body: {'community_id': widget.id, 'name': name, 'description': desc}); if (mounted) setState(reload);} catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => CirclePage(title: 'Сообщество', child: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Нет доступа к сообществу', description: '${snapshot.error}');
    if (!snapshot.hasData) return const CircleLoadingState();
    final community = obj(snapshot.data!['community']);
    final channels = (community['channels'] as List? ?? []).whereType<Map>().toList();
    final voice = (community['voice_channels'] as List? ?? []).whereType<Map>().toList();
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1050), child: ListView(padding: const EdgeInsets.all(24), children: [
      CircleSurface(padding: EdgeInsets.zero, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 136, decoration: BoxDecoration(borderRadius: const BorderRadius.vertical(top: Radius.circular(17)), gradient: LinearGradient(colors: [circleGold.withValues(alpha: .29), const Color(0xFF25272E), circleSidebar]))),
        Padding(padding: const EdgeInsets.all(22), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${community['name'] ?? ''}', style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 8), Text('${community['description'] ?? ''}'),
          const SizedBox(height: 14), Wrap(spacing: 10, runSpacing: 8, children: [
            if (community['can_post_news'] == true) FilledButton.icon(onPressed: publish, icon: const Icon(Icons.edit_note_rounded), label: const Text('Новая новость')),
            if (['OWNER', 'ADMIN'].contains('${community['role'] ?? ''}'.toUpperCase())) OutlinedButton.icon(onPressed: () => manage(community), icon: const Icon(Icons.edit_outlined), label: const Text('Описание')),
            OutlinedButton.icon(onPressed: () => Navigator.push(context,
              MaterialPageRoute(builder: (_) => CirclePage(title:'Статистика сообщества',
                child:CircleCommunityStatsScreen(widget.api, widget.id)))),
              icon: const Icon(Icons.bar_chart_rounded), label: const Text('Статистика')),
            if (['OWNER', 'ADMIN'].contains('${community['role'] ?? ''}'.toUpperCase())) FilledButton.tonalIcon(onPressed: () => Navigator.push(context, MaterialPageRoute(builder: (_) => DesktopCommunityTools(widget.api, widget.id))), icon: const Icon(Icons.tune), label: const Text('Панель сообщества')),
            if ('${community['role'] ?? ''}'.toUpperCase() == 'MEMBER') TextButton.icon(onPressed: () async {if(!await fxConfirm(context, 'Выйти из сообщества?', 'Ты больше не сможешь читать его материалы без нового приглашения.'))return;try {await widget.api.call('desktop-community-leave', body: {'community_id': widget.id});if(context.mounted)Navigator.pop(context);}catch(e){if(context.mounted)fxNotice(context,e);}}, icon: const Icon(Icons.logout), label: const Text('Покинуть')),
          ]),
        ])),
      ])),
      const SizedBox(height: 24), CircleSection(title: 'Текстовые каналы', subtitle: '${channels.length} доступных каналов'), const SizedBox(height: 12),
      if (channels.isEmpty) const CircleSurface(child: Text('Текстовых каналов пока нет')),
      for (final channel in channels) Padding(padding: const EdgeInsets.only(bottom: 8), child: CircleSurface(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 5), child: ListTile(leading: const Icon(Icons.tag, color: circleGold), title: Text('${channel['name'] ?? ''}'), trailing: const Icon(Icons.chevron_right), onTap: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => ChannelScreen(widget.api, identifier(channel['id']), '${channel['name']}')))))),
      if (voice.isNotEmpty) ...[const SizedBox(height: 18), const CircleSection(title: 'Голосовые каналы'), const SizedBox(height: 12), for (final v in voice) Padding(padding: const EdgeInsets.only(bottom: 8), child: CircleSurface(child: Row(children: [const Icon(Icons.graphic_eq, color: circleGold), const SizedBox(width: 10), Text('${v['name']}'), const Spacer(), OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CircleLiveRoom(title: 'Голосовой канал · ${v['name']}', credentials: () => widget.api.call('mobile-voice-token', body: {'voice_channel_id': identifier(v['id'])})))), icon: const Icon(Icons.headset_mic_outlined), label: const Text('Подключиться'))])))],
      const SizedBox(height: 22), const CircleSection(title: 'Новости сообщества'), const SizedBox(height: 12),
      SizedBox(height: 600, child: FeedScreen(widget.api, route: 'community-feed', query: {'id': '${widget.id}'})),
    ])));
  }));
}
class ChannelScreen extends StatefulWidget {
  const ChannelScreen(this.api, this.id, this.name, {super.key});
  final CircleApi api;
  final int id;
  final String name;
  @override State<ChannelScreen> createState() => _ChannelScreenState();
}
class _ChannelScreenState extends State<ChannelScreen> {
  final controller = TextEditingController();
  int? reply;
  int reload = 0;
  @override void dispose() {controller.dispose(); super.dispose();}
  Future<void> send() async {
    final body = controller.text.trim();
    if (body.isEmpty) return;
    try {
      await widget.api.call('channel-send', body: {'channel_id': widget.id, 'body': body, 'reply_to_id': reply ?? 0});
      controller.clear();
      if (mounted) setState(() {reply = null; reload++;});
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> channelAction(Map<String,dynamic> message,String action) async {
    final mid=identifier(message['id']);
    if(action=='reply'){setState(()=>reply=mid);return;}
    final route={'edit':'desktop-channel-edit','delete':'desktop-channel-message-delete','pin':'desktop-channel-pin','report':'desktop-channel-report'}[action];
    if(route==null)return;
    String? value;
    if(action=='edit'||action=='report'){
      value=await fxPrompt(context,action=='edit'?'Изменить сообщение':'Причина жалобы',initial:action=='edit'?'${message['body'] ?? ''}':'',lines:3);
      if(!mounted||value==null)return;
    }
    if(action=='delete'&&!await fxConfirm(context,'Удалить сообщение?','Сообщение и вложения будут удалены.'))return;
    try {await widget.api.call(route,body:{'message_id':mid,if(action=='edit')'body':value,if(action=='report')'reason':value});
      if(mounted){fxNotice(context,'Сохранено');setState(()=>reload++);}}
    catch(e){if(mounted)fxNotice(context,e);}
  }
  @override Widget build(BuildContext context) => CirclePage(title: '# ${widget.name}', child: Column(children: [
    Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: 'channel-messages', query: {'channel_id': '${widget.id}'}, emptyTitle: 'В канале пока тихо', itemBuilder: (context, message, refresh) => CircleSurface(padding: const EdgeInsets.all(14), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CircleUserAvatar(api: widget.api, user: obj(message['author']), radius: 20), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(label(obj(message['author'])), style: const TextStyle(fontWeight: FontWeight.w700))), Text(circleDate(message['created_at']), style: const TextStyle(color: circleMuted, fontSize: 11))]),
        if (message['reply_to_id'] != null) Text('↳ Ответ на #${message['reply_to_id']}', style: const TextStyle(fontSize: 11, color: circleGold)),
        const SizedBox(height: 6), Text('${message['body'] ?? ''}'),
        Wrap(children: [TextButton(onPressed: () => channelAction(message,'reply'), child: const Text('Ответить')), PopupMenuButton<String>(tooltip:'Действия',icon:const Icon(Icons.more_horiz),onSelected:(value)=>channelAction(message,value),itemBuilder:(_)=>const [PopupMenuItem(value:'edit',child:Text('Изменить моё сообщение')),PopupMenuItem(value:'delete',child:Text('Удалить')),PopupMenuItem(value:'pin',child:Text('Закрепить')),PopupMenuItem(value:'report',child:Text('Пожаловаться'))]), for (final reaction in ['❤️', '👍', '😂']) TextButton(onPressed: () async {try {await widget.api.call('channel-react', body: {'message_id': identifier(message['id']), 'emoji': reaction}); if (context.mounted) refresh();} catch (e) {if (context.mounted) notify(context, '$e');}}, child: Text(reaction))]),
      ])),
    ])))),
    if (reply != null) Padding(padding: const EdgeInsets.all(8), child: Text('Ответ на #$reply', style: const TextStyle(color: circleGold))),
    Padding(padding: const EdgeInsets.all(14), child: Row(children: [Expanded(child: TextField(controller: controller, maxLines: 3, minLines: 1, maxLength: 4000, decoration: const InputDecoration(hintText: 'Сообщение в канал...', counterText: ''))), IconButton(onPressed: send, icon: const Icon(Icons.send, color: circleGold))])),
  ]));
}

class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen(this.api, {super.key});
  final CircleApi api;
  @override State<NotificationsScreen> createState() => _NotificationsScreenState();
}
class _NotificationsScreenState extends State<NotificationsScreen> {
  int reload = 0;
  Future<void> read(int id) async {
    try {await widget.api.call('notification-read', body: {'id': id}); if (mounted) setState(() => reload++);}
    catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Column(children: [
    Padding(padding: const EdgeInsets.fromLTRB(24, 26, 24, 14), child: CircleSection(title: 'Уведомления', subtitle: 'Важное из твоего круга', trailing: Wrap(spacing: 8, children: [
      OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => NotificationSettingsScreen(widget.api))), icon: const Icon(Icons.tune, size: 17), label: const Text('Настроить')),
      FilledButton.icon(onPressed: () => read(0), icon: const Icon(Icons.done_all, size: 17), label: const Text('Прочитать все')),
    ]))),
    Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: 'notifications', emptyTitle: 'Новых уведомлений нет', itemBuilder: (context, n, refresh) {
      final unread = n['read'] != true;
      return CircleSurface(accent: unread, padding: const EdgeInsets.symmetric(horizontal: 17, vertical: 13), child: Row(children: [
        Container(padding: const EdgeInsets.all(11), decoration: BoxDecoration(color: circleGold.withValues(alpha: .1), borderRadius: BorderRadius.circular(12)), child: const Icon(Icons.notifications_none, color: circleGold)), const SizedBox(width: 13),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${n['actor_name'] ?? 'Circle'}', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 4), Text(_notificationLabel('${n['kind'] ?? ''}'), style: const TextStyle(color: circleMuted)), const SizedBox(height: 6), Text(circleDate(n['created_at']), style: Theme.of(context).textTheme.bodySmall)])),
        if (unread) TextButton(onPressed: () => read(identifier(n['id'])), child: const Text('Прочитано')),
      ]));
    })),
  ])));
  String _notificationLabel(String key) => switch (key) {
    'dm_message' => 'Новое личное сообщение', 'dm_call' => 'Входящий звонок',
    'friend_request' => 'Запрос в друзья', 'friend_accepted' => 'Новый друг',
    'post_comment' => 'Новый комментарий', 'post_like' => 'Реакция на публикацию',
    _ => key.replaceAll('_', ' '),
  };
}

class NotificationSettingsScreen extends StatefulWidget {
  const NotificationSettingsScreen(this.api, {super.key});
  final CircleApi api;
  @override State<NotificationSettingsScreen> createState() => _NotificationSettingsScreenState();
}
class _NotificationSettingsScreenState extends State<NotificationSettingsScreen> {
  late Future<Map<String, dynamic>> future;
  @override void initState() {super.initState(); reload();}
  void reload() {future = widget.api.call('notification-settings');}
  Future<void> change(String key, bool value, Map<String, dynamic> settings) async {
    try {await widget.api.call('notification-settings', body: {key: value}); if (mounted) setState(reload);}
    catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => CirclePage(title: 'Настройки уведомлений', child: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Не удалось получить настройки', description: '${snapshot.error}');
    if (!snapshot.hasData) return const CircleLoadingState();
    final settings = obj(snapshot.data!['settings']);
    const captions = {'messages': 'Личные сообщения', 'friends': 'Друзья и заявки', 'communities': 'Сообщества', 'security_alerts': 'Безопасность аккаунта', 'system': 'Системные уведомления', 'push_enabled': 'Push-уведомления'};
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 700), child: ListView(padding: const EdgeInsets.all(22), children: [
      CircleSurface(child: Column(children: [for (final item in captions.entries) SwitchListTile(title: Text(item.value), subtitle: item.key == 'push_enabled' ? const Text('Windows push не подключён к серверному API') : null, activeThumbColor: circleGold,
        value: settings[item.key] == true, onChanged: item.key == 'push_enabled' && snapshot.data!['push_available'] != true ? null : (value) => change(item.key, value, settings))])),
    ])));
  }));
}

class CallsScreen extends StatelessWidget {
  const CallsScreen(this.api, {super.key});
  final CircleApi api;
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 850), child: Column(children: [
    const Padding(padding: EdgeInsets.fromLTRB(24, 26, 24, 18), child: CircleSection(title: 'Звонки', subtitle: 'История личных звонков Circle')),
    Expanded(child: ApiList(api: api, route: 'mobile-call-history', emptyTitle: 'Звонков ещё не было', itemBuilder: (context, call, refresh) => CircleSurface(padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10), child: Row(children: [
      const Icon(Icons.call_outlined, color: circleGold), const SizedBox(width: 15),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Звонок #${call['id'] ?? ''}', style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 5), Text('${call['status'] ?? ''} · ${circleDate(call['created_at'])}', style: Theme.of(context).textTheme.bodySmall)])),
      const Icon(Icons.history, color: circleMuted),
    ])))),
    const Padding(padding: EdgeInsets.all(18), child: Text('Начните звонок в мессенджере. Входящие вызовы отображаются при открытом приложении.', style: TextStyle(color: circleMuted, fontSize: 11), textAlign: TextAlign.center)),
  ])));
}

class UpdatesScreen extends StatefulWidget {
  const UpdatesScreen({super.key, this.initialRelease});
  final UpdateInfo? initialRelease;
  @override State<UpdatesScreen> createState() => _UpdatesScreenState();
}
class _UpdatesScreenState extends State<UpdatesScreen> {
  bool busy = false;
  double? progress;
  String status = 'Circle проверяет обновления через GitHub Releases.';
  @override void initState() {
    super.initState();
    if (widget.initialRelease != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) install(widget.initialRelease!);
      });
    }
  }

  CircleUpdater? get updater {
    final uri = circleUpdateUri;
    if (uri == null || updatePublicKey.isEmpty) return null;
    return CircleUpdater(manifestUrl: uri, publicKeyBase64: updatePublicKey);
  }
  Future<void> check() async {
    final service = updater;
    if (service == null) {
      setState(() => status = 'Подписанный канал не настроен. Владелец репозитория должен один раз запустить GitHub Actions → Circle signing key setup, затем пересобрать приложение.');
      return;
    }
    setState(() {busy = true; status = 'Проверяю релизы GitHub...'; progress = null;});
    try {
      final release = await service.check(appVersion);
      if (!mounted) return;
      if (release == null) {
        setState(() => status = 'Установлена актуальная версия Circle $appVersion.');
        return;
      }
      final accepted = await showDialog<bool>(context: context, builder: (dialog) => AlertDialog(
        title: Text('Обновление ${release.version}'),
        content: Text('Скачать обновление из GitHub, проверить цифровую подпись и заменить файлы приложения?\n\n${release.notes}'),
        actions: [TextButton(onPressed: () => Navigator.pop(dialog, false), child: const Text('Позже')),
          FilledButton(onPressed: () => Navigator.pop(dialog, true), child: const Text('Скачать и установить'))]));
      if (accepted == true && mounted) await install(release);
    } catch (e, stack) {
      CircleStartupLog.report('check update', e, stack);
      if (mounted) setState(() => status = 'Не удалось проверить обновления: $e');
    } finally {
      service.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> install(UpdateInfo release) async {
    final service = updater;
    if (service == null) return;
    setState(() {busy = true; progress = 0; status = 'Загружаю Circle ${release.version}...';});
    try {
      var lastPercent = -1;
      final payload = await service.downloadVerified(release, onProgress: (value) {
        final percent = (value * 100).round();
        // Avoid repainting the whole screen for every network packet.
        if (percent != lastPercent && mounted) {
          lastPercent = percent;
          setState(() => progress = value);
        }
      });
      if (!mounted) return;
      setState(() {progress = 1; status = 'Архив проверен. Готовлю файлы к замене, Circle пока остаётся открытым...';});
      await CircleUpdater.installAndRestart(release, payload);
    } catch (e, stack) {
      CircleStartupLog.report('install update', e, stack);
      if (mounted) setState(() => status = 'Обновление не выполнено: $e');
    } finally {
      service.close();
      if (mounted) setState(() => busy = false);
    }
  }
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 650),
    child: Padding(padding: const EdgeInsets.all(25), child: CircleSurface(
      padding: const EdgeInsets.all(35), accent: true,
      child: Column(mainAxisSize: MainAxisSize.min, children: [
        Container(padding: const EdgeInsets.all(21), decoration: BoxDecoration(
          shape: BoxShape.circle, color: circleGold.withValues(alpha: .12)),
          child: const Icon(Icons.system_update_alt_rounded, size: 38, color: circleGold)),
        const SizedBox(height: 18), Text('Circle для Windows', style: Theme.of(context).textTheme.headlineSmall),
        const SizedBox(height: 8), const Text('Версия $appVersion', style: TextStyle(color: circleGoldBright)),
        const SizedBox(height: 18), Text(status, style: const TextStyle(color: circleMuted), textAlign: TextAlign.center),
        if (progress != null) Padding(padding: const EdgeInsets.only(top: 18), child: Column(children: [
          LinearProgressIndicator(value: progress, minHeight: 5, backgroundColor: circleStroke),
          const SizedBox(height: 8), Text('${((progress ?? 0) * 100).round()}%',
            style: const TextStyle(color: circleGoldBright))])),
        const SizedBox(height: 24), FilledButton.icon(onPressed: busy ? null : check,
          icon: busy ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.refresh),
          label: Text(busy ? 'Выполняется...' : 'Проверить GitHub')),
        const SizedBox(height: 16), const Text('Обновление не удаляет сообщения и учётную запись. При неудаче сохранённая версия восстанавливается автоматически.',
          textAlign: TextAlign.center, style: TextStyle(fontSize: 11, color: circleMuted)),
      ])))));
}

class CinemaRoomsScreen extends StatelessWidget {
  const CinemaRoomsScreen(this.api, {super.key});
  final CircleApi api;
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: Column(children: [
    const Padding(padding: EdgeInsets.fromLTRB(24, 24, 24, 16), child: CircleSection(title: 'Совместный просмотр', subtitle: 'Кинозалы, в которых ты участвуешь')),
    Expanded(child: ApiList(api: api, route: 'cinema-rooms', emptyTitle: 'Нет активных кинозалов', itemBuilder: (context, room, refresh) => CircleSurface(child: Row(children: [const Icon(Icons.movie_outlined, size: 30, color: circleGold), const SizedBox(width: 18), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${room['title'] ?? 'Кинозал'}', style: Theme.of(context).textTheme.titleMedium), Text('${room['provider'] ?? ''}', style: Theme.of(context).textTheme.bodySmall)])), Text('#${room['id']}', style: const TextStyle(color: circleMuted))])))),
  ])));
}

class AdminSummaryScreen extends StatelessWidget {
  const AdminSummaryScreen(this.api, {super.key});
  final CircleApi api;
  @override Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(
    future: api.call('admin-summary'), builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Нет доступа к статистике', description: '${snapshot.error}');
      if (!snapshot.hasData) return const CircleLoadingState();
      final summary = snapshot.data!;
      final cases = (summary['cases'] as List? ?? []).whereType<Map>().toList();
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: ListView(padding: const EdgeInsets.all(24), children: [
        const CircleSection(title: 'Панель администратора', subtitle: 'Обзор пользователей и заявок на проверку'),
        const SizedBox(height: 20), Row(children: [Expanded(child: CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Пользователи', style: TextStyle(color: circleMuted)), const SizedBox(height: 8), Text('${summary['users'] ?? '—'}', style: Theme.of(context).textTheme.headlineMedium)]))), const SizedBox(width: 13), Expanded(child: CircleSurface(accent: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('На модерации', style: TextStyle(color: circleMuted)), const SizedBox(height: 8), Text('${summary['pending'] ?? '—'}', style: Theme.of(context).textTheme.headlineMedium)])))]),
        const SizedBox(height: 24), const CircleSection(title: 'Ожидают проверки'), const SizedBox(height: 12),
        if (cases.isEmpty) const CircleSurface(child: Text('Новых заявок нет')),
        for (final item in cases) Padding(padding: const EdgeInsets.only(bottom: 10), child: CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Заявка #${item['id']} · ${item['source_type'] ?? ''}', style: const TextStyle(color: circleGold, fontWeight: FontWeight.w700)), const SizedBox(height: 7), Text('${item['excerpt'] ?? ''}'), const SizedBox(height: 6), Text('Пользователь: ${item['username'] ?? ''}', style: const TextStyle(color: circleMuted, fontSize: 12))]))),
        const SizedBox(height: 12), const Text('Для рассмотрения обычных жалоб и архива решений откройте раздел «Жалобы и архив» в боковой панели. Trust & Safety доступен отдельным разделом.', style: TextStyle(fontSize: 12, color: circleMuted)),
      ])));
    },
  );
}

class RewardSettingsScreen extends StatefulWidget {
  const RewardSettingsScreen(this.api, {super.key});
  final CircleApi api;
  @override State<RewardSettingsScreen> createState() => _RewardSettingsScreenState();
}
class _RewardSettingsScreenState extends State<RewardSettingsScreen> {
  late Future<Map<String, dynamic>> future;
  @override void initState() {super.initState(); reload();}
  void reload() {future = widget.api.call('reward-options');}
  Future<void> choose(String frame, String status) async {
    try {await widget.api.call('reward-select', body: {'frame': frame, 'status': status}); if (mounted) setState(reload);}
    catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => CirclePage(title: 'Награды и оформление', child: FutureBuilder<Map<String, dynamic>>(future: future, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Награды недоступны', description: '${snapshot.error}');
    if (!snapshot.hasData) return const CircleLoadingState();
    final data = snapshot.data!;
    final frames = (data['frames'] as List? ?? []).whereType<Map>().toList();
    final statuses = (data['statuses'] as List? ?? []).whereType<Map>().toList();
    final frame = '${data['selected_frame'] ?? ''}';
    final status = '${data['selected_status'] ?? ''}';
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 650), child: ListView(padding: const EdgeInsets.all(22), children: [
      const CircleSection(title: 'Твои достижения', subtitle: 'Открытые награды для оформления профиля'), const SizedBox(height: 16),
      CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Рамка аватара', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 12),
        DropdownButtonFormField<String>(initialValue: frames.any((v) => '${v['key']}' == frame) ? frame : null, hint: const Text('Без рамки'),
          items: [const DropdownMenuItem(value: '', child: Text('Без рамки')), for (final v in frames) DropdownMenuItem(value: '${v['key']}', child: Text('${v['name']}'))],
          onChanged: (value) {if (value != null) choose(value, status);}),
        const SizedBox(height: 20), Text('Статус', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 12),
        DropdownButtonFormField<String>(initialValue: statuses.any((v) => '${v['key']}' == status) ? status : null, hint: const Text('Без статуса'),
          items: [const DropdownMenuItem(value: '', child: Text('Без статуса')), for (final v in statuses) DropdownMenuItem(value: '${v['key']}', child: Text('${v['name']}'))],
          onChanged: (value) {if (value != null) choose(frame, value);}),
      ])),
    ])));
  }));
}
