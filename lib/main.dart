import 'dart:io';
import 'dart:async';
import 'dart:ui' show PlatformDispatcher;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
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

const secure = FlutterSecureStorage();
const updateManifest = String.fromEnvironment('CIRCLE_UPDATE_URL');
const updatePublicKey = String.fromEnvironment('CIRCLE_UPDATE_PUBLIC_KEY');
const appVersion = '0.4.2';

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
  Timer? incomingTimer;
  int page = 0;
  String error = '';
  @override void initState() {super.initState(); restore();}
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
      if (mounted) {setState(() {api?.dispose(); api = candidate; me = obj(data['user']);}); candidate = null; beginIncomingPolling();}
    } catch (e) {if (mounted) setState(() => error = '$e');}
    finally {candidate?.dispose(); if (mounted) setState(() => loading = false);}
  }
  Future<void> logout() async {
    try {await api?.call('logout', body: {});} catch (_) { /* Local sign-out still applies. */ }
    await secure.delete(key: 'circle_token');
    incomingTimer?.cancel(); incomingTimer = null;
    api?.dispose();
    if (mounted) setState(() {api = null; me = {}; page = 0;});
  }
  void openSecondary(String title, Widget child) {
    Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CirclePage(title: title, child: child)));
  }
  void beginIncomingPolling() {
    incomingTimer?.cancel();
    incomingTimer = Timer.periodic(const Duration(seconds: 9), (_) => pollIncoming());
  }
  Future<void> pollIncoming() async {
    if (api == null || incomingDialog || !mounted) return;
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
    finally {incomingDialog = false;}
  }
  @override void dispose() {incomingTimer?.cancel(); api?.dispose(); super.dispose();}
  @override Widget build(BuildContext context) {
    if (loading) return const Scaffold(body: Center(child: CircularProgressIndicator(color: circleGold)));
    if (api == null) return LoginScreen(onLogin: login, error: error);
    final client = api!;
    final small = MediaQuery.sizeOf(context).width < 970;
    final mini = small || collapsed;
    final width = mini ? 78.0 : 246.0;
    final screens = [
      FeedScreen(client), ProfileScreen(client), MessengerScreen(client, me: me), FriendsScreen(client),
    ];
    final names = ['Главная', 'Профиль', 'Мессенджер', 'Друзья'];
    final icons = [Icons.home_rounded, Icons.account_circle_outlined, Icons.forum_outlined, Icons.people_outline_rounded];
    return Scaffold(body: Row(children: [
      AnimatedContainer(duration: const Duration(milliseconds: 180), width: width,
        decoration: BoxDecoration(color: widget.light ? const Color(0xFFEAE5DC) : circleSidebar,
          border: Border(right: BorderSide(color: Theme.of(context).dividerColor))),
        child: SafeArea(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: EdgeInsets.fromLTRB(mini ? 16 : 19, 24, 8, 34), child: CircleLogo(compact: mini, size: 43)),
          for (var i = 0; i < names.length; i++) Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 7),
            child: Tooltip(message: names[i], child: InkWell(borderRadius: BorderRadius.circular(13), onTap: () => setState(() => page = i),
              child: AnimatedContainer(duration: const Duration(milliseconds: 180), height: 51,
                padding: EdgeInsets.symmetric(horizontal: mini ? 13 : 17),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(13),
                  color: page == i ? circleGold.withValues(alpha: .12) : Colors.transparent,
                  border: Border.all(color: page == i ? circleGold.withValues(alpha: .62) : Colors.transparent),
                  boxShadow: page == i ? [BoxShadow(color: circleGold.withValues(alpha: .08), blurRadius: 19)] : [],
                ), child: Row(children: [Icon(icons[i], color: page == i ? circleGoldBright : circleMuted, size: 23),
                  if (!mini) ...[const SizedBox(width: 14), Text(names[i], style: TextStyle(fontWeight: FontWeight.w600, color: page == i ? Theme.of(context).colorScheme.onSurface : circleMuted))],
                ])))),
          ),
          const Spacer(),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 14), child: Divider(color: Theme.of(context).dividerColor)),
          if (!mini) Padding(padding: const EdgeInsets.fromLTRB(20, 10, 8, 9), child: Text('РАЗДЕЛЫ', style: Theme.of(context).textTheme.bodySmall?.copyWith(letterSpacing: 2, fontSize: 10))),
          _secondaryNav(mini, Icons.groups_2_outlined, 'Сообщества', () => openSecondary('Сообщества', CommunitiesScreen(client))),
          _secondaryNav(mini, Icons.call_outlined, 'Звонки', () => openSecondary('Звонки', CallsScreen(client))),
          _secondaryNav(mini, Icons.local_movies_outlined, 'Кинозалы', () => openSecondary('Кинозалы', CinemaRoomsScreen(client))),
          if (['OWNER', 'ADMIN'].contains('${me['platform_role'] ?? ''}'.toUpperCase()))
            _secondaryNav(mini, Icons.admin_panel_settings_outlined, 'Администрирование', () => openSecondary('Администрирование', AdminSummaryScreen(client))),
          _secondaryNav(mini, Icons.settings_outlined, 'Обновления', () => openSecondary('Обновления', const UpdatesScreen())),
          const SizedBox(height: 16),
          Padding(padding: const EdgeInsets.all(12), child: InkWell(onTap: () => setState(() => page = 1), borderRadius: BorderRadius.circular(13),
            child: Container(padding: const EdgeInsets.all(9), decoration: BoxDecoration(borderRadius: BorderRadius.circular(13), color: circleGold.withValues(alpha: .07)),
              child: Row(children: [CircleUserAvatar(api: client, user: me, radius: 19), if (!mini) ...[const SizedBox(width: 10), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(me), maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 12)), Text('@${me['username'] ?? ''}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10, color: circleMuted))]))]])))),
        ]))),
      Expanded(child: Column(children: [
        Container(height: 72, decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))),
          padding: const EdgeInsets.symmetric(horizontal: 23), child: Row(children: [
            IconButton(tooltip: mini && small ? 'Навигация свёрнута' : 'Свернуть боковую панель', onPressed: small ? null : () => setState(() => collapsed = !collapsed), icon: Icon(mini ? Icons.menu_open : Icons.menu)),
            const SizedBox(width: 12), Expanded(child: Text(names[page], style: Theme.of(context).textTheme.titleLarge)),
            IconButton(tooltip: 'Сообщества', onPressed: () => openSecondary('Сообщества', CommunitiesScreen(client)), icon: const Icon(Icons.groups_outlined)),
            IconButton(tooltip: 'Звонки', onPressed: () => openSecondary('Звонки', CallsScreen(client)), icon: const Icon(Icons.call_outlined)),
            IconButton(tooltip: 'Уведомления', onPressed: () => openSecondary('Уведомления', NotificationsScreen(client)), icon: const Icon(Icons.notifications_none)),
            IconButton(tooltip: 'Переключить тему', onPressed: widget.onTheme, icon: Icon(widget.light ? Icons.dark_mode_outlined : Icons.light_mode_outlined)),
            PopupMenuButton<String>(tooltip: 'Аккаунт', onSelected: (choice) {if (choice == 'logout') logout(); if (choice == 'updates') openSecondary('Обновления', const UpdatesScreen());},
              itemBuilder: (_) => const [PopupMenuItem(value: 'updates', child: Text('Обновления Circle')), PopupMenuItem(value: 'logout', child: Text('Выйти из аккаунта'))],
              child: Padding(padding: const EdgeInsets.only(left: 9), child: CircleUserAvatar(api: client, user: me, radius: 17))),
          ])),
        Expanded(child: IndexedStack(index: page, children: screens)),
      ])),
    ]));
  }
  Widget _secondaryNav(bool mini, IconData icon, String title, VoidCallback tap) => Padding(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
    child: Tooltip(message: title, child: InkWell(borderRadius: BorderRadius.circular(12), onTap: tap,
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 12), child: Row(children: [Icon(icon, color: circleMuted, size: 21), if (!mini) ...[const SizedBox(width: 14), Text(title, style: const TextStyle(color: circleMuted, fontSize: 13))]])))),
  );
}

class CirclePage extends StatelessWidget {
  const CirclePage({super.key, required this.title, required this.child});
  final String title;
  final Widget child;
  @override Widget build(BuildContext context) => Scaffold(appBar: AppBar(title: Text(title), leading: IconButton(icon: const Icon(Icons.arrow_back), onPressed: () => Navigator.pop(context))), body: child);
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
            const SizedBox(height: 24), SizedBox(width: double.infinity, child: FilledButton(onPressed: _submit, child: const Padding(padding: EdgeInsets.all(6), child: Text('Войти в Circle')))),
            const SizedBox(height: 20), const Center(child: Text('Нативное приложение для Windows', style: TextStyle(color: circleMuted, fontSize: 11))),
          ]))),
        ])),
    )));
  }
  void _submit() {widget.onLogin(host.text.trim(), user.text.trim(), pass.text, totp.text.trim());}
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
    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
    final data = snapshot.data!;
    return RefreshIndicator(onRefresh: () async {refresh(); await future;}, child: data.isEmpty
      ? ListView(children: [SizedBox(height: 350, child: CircleEmpty(title: widget.emptyTitle, icon: Icons.inbox_outlined))])
      : ListView(padding: widget.padding, children: [for (final item in data) Padding(padding: const EdgeInsets.only(bottom: 12), child: widget.itemBuilder(context, item, refresh))]));
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
  int reload = 0;
  Future<void> createPost({bool media = false}) async {
    final title = await compose(context, 'Заголовок публикации', maxLength: 140);
    if (!mounted || title == null || title.isEmpty) return;
    final body = await compose(context, 'Текст публикации', maxLength: 4000);
    if (!mounted || body == null) return;
    try {
      if (media) {
        final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm']);
        if (picked == null || picked.files.single.path == null) return;
        await widget.api.upload('post-upload', File(picked.files.single.path!), field: 'media', fields: {'title': title, 'body': body});
      } else {
        await widget.api.call('post-create', body: {'title': title, 'body': body});
      }
      if (mounted) {notify(context, 'Публикация создана'); setState(() => reload++);}
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) {
    final isHome = widget.route == 'feed';
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: Column(children: [
      if (isHome) Expanded(child: CustomScrollView(slivers: [
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 27, 24, 14), child: const CircleSection(title: 'Твой круг', subtitle: 'Новости людей и сообществ, которые тебе близки'))),
        SliverToBoxAdapter(child: SizedBox(height: 130, child: StoriesStrip(widget.api))),
        SliverToBoxAdapter(child: Padding(padding: const EdgeInsets.fromLTRB(24, 6, 24, 18), child: CircleSurface(padding: const EdgeInsets.all(17), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [const Icon(Icons.edit_square, color: circleGold, size: 21), const SizedBox(width: 11), Expanded(child: Text('Есть чем поделиться?', style: Theme.of(context).textTheme.titleMedium))]),
          const SizedBox(height: 15), Row(children: [Expanded(child: FilledButton.icon(onPressed: () => createPost(), icon: const Icon(Icons.add, size: 18), label: const Text('Новая публикация'))), const SizedBox(width: 10), Expanded(child: OutlinedButton.icon(onPressed: () => createPost(media: true), icon: const Icon(Icons.image_outlined, size: 18), label: const Text('Фото / видео')))]),
        ])))),
        SliverFillRemaining(child: ApiList(key: ValueKey(reload), api: widget.api, route: widget.route, query: widget.query, padding: const EdgeInsets.fromLTRB(24, 0, 24, 30), emptyTitle: 'Лента пока пуста', itemBuilder: (context, post, refresh) => PostCard(widget.api, post, refresh))),
      ])) else Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: widget.route, query: widget.query,
        emptyTitle: 'Публикаций пока нет', itemBuilder: (context, post, refresh) => PostCard(widget.api, post, refresh))),
    ])));
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
    return CircleSurface(padding: const EdgeInsets.all(21), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [CircleUserAvatar(api: api, user: author, radius: 21), const SizedBox(width: 12),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Flexible(child: Text(label(author), overflow: TextOverflow.ellipsis, style: Theme.of(context).textTheme.titleMedium)), if (author['verified'] == true) const Padding(padding: EdgeInsets.only(left: 5), child: Icon(Icons.verified_rounded, color: circleGold, size: 16))]),
          const SizedBox(height: 3), Text('${circleDate(post['created_at'])}${community.isEmpty ? '' : '  ·  ${community['name'] ?? ''}'}', style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis),
        ])),
        const Icon(Icons.more_horiz, color: circleMuted),
      ]),
      if (title.isNotEmpty) ...[const SizedBox(height: 16), Text(title, style: Theme.of(context).textTheme.titleLarge)],
      if (body.isNotEmpty) ...[const SizedBox(height: 9), SelectableText(body, style: Theme.of(context).textTheme.bodyMedium)],
      if (post['has_media'] == true) Padding(padding: const EdgeInsets.only(top: 15), child: CircleMedia(api: api, route: 'post-media', id: id, mime: '${post['media_mime'] ?? ''}')),
      const SizedBox(height: 14), Divider(color: Theme.of(context).dividerColor, height: 1),
      const SizedBox(height: 10), Wrap(spacing: 15, runSpacing: 5, children: [
        TextButton.icon(onPressed: () async {try {await api.call('post-like', body: {'post_id': id}); refresh();} catch (e) {if (context.mounted) notify(context, '$e');}}, icon: Icon(stats['liked'] == true || stats['mine'] == true ? Icons.favorite_rounded : Icons.favorite_border_rounded, size: 19), label: Text('${stats['likes'] ?? 0}  Нравится')),
        TextButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CommentsScreen(api, id))), icon: const Icon(Icons.mode_comment_outlined, size: 19), label: Text('${stats['comments'] ?? 0}  Комментарии')),
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
        Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => setState(() => reply = identifier(comment['id'])), child: const Text('Ответить'))),
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
  late Future<Map<String, dynamic>> profile;
  @override void initState() {super.initState(); reload();}
  void reload() {profile = widget.api.call('profile');}
  Future<void> edit(Map<String, dynamic> data) async {
    final person = obj(data['user']);
    if (!mounted) return;
    final name = await compose(context, 'Отображаемое имя', initial: label(person), maxLength: 60);
    if (!mounted || name == null || name.isEmpty) return;
    final bio = await compose(context, 'О себе', initial: '${data['bio'] ?? ''}', maxLength: 500);
    if (!mounted || bio == null) return;
    final status = await compose(context, 'Статус', initial: '${data['status_text'] ?? ''}', maxLength: 80);
    if (!mounted || status == null) return;
    try {
      await widget.api.call('profile-save', body: {'display_name': name, 'bio': bio, 'status_text': status, 'visibility': '${data['visibility'] ?? 'PUBLIC'}'});
      if (mounted) setState(reload);
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> uploadAvatar() async {
    final picked = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: ['jpg', 'jpeg', 'png', 'webp']);
    if (picked?.files.single.path == null) return;
    try {
      await widget.api.upload('avatar-upload', File(picked!.files.single.path!), field: 'avatar');
      if (mounted) setState(() {avatarVersion++; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  @override Widget build(BuildContext context) => FutureBuilder<Map<String, dynamic>>(future: profile, builder: (context, snapshot) {
    if (snapshot.hasError) return CircleEmpty(title: 'Профиль не загрузился', description: '${snapshot.error}', action: OutlinedButton(onPressed: () => setState(reload), child: const Text('Повторить')));
    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
    final data = snapshot.data!;
    final person = obj(data['user']);
    final counts = obj(data['counts']);
    return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1030), child: ListView(padding: const EdgeInsets.fromLTRB(24, 26, 24, 35), children: [
      CircleSurface(padding: EdgeInsets.zero, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Container(height: 195, decoration: BoxDecoration(borderRadius: const BorderRadius.vertical(top: Radius.circular(18)),
          gradient: LinearGradient(begin: Alignment.topLeft, end: Alignment.bottomRight, colors: [const Color(0xFF282521), circleGold.withValues(alpha: .22), const Color(0xFF141519)])),
          child: Stack(children: [
            if (data['cover_url'] != null) Positioned.fill(child: ClipRRect(borderRadius: const BorderRadius.vertical(top: Radius.circular(18)), child: CircleRemoteImage(api: widget.api, route: 'profile-cover', id: identifier(person['id'])))),
            Positioned(right: 30, top: -58, child: Container(width: 320, height: 320, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold.withValues(alpha: .15), width: 2)))),
            Positioned(right: 75, top: -15, child: Container(width: 235, height: 235, decoration: BoxDecoration(shape: BoxShape.circle, border: Border.all(color: circleGold.withValues(alpha: .23))))),
            const Positioned(bottom: 28, left: 28, child: Text('МОЙ ПРОФИЛЬ', style: TextStyle(letterSpacing: 3, color: circleGoldBright, fontWeight: FontWeight.w700, fontSize: 11))),
          ])),
        Padding(padding: const EdgeInsets.fromLTRB(26, 0, 26, 25), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Transform.translate(offset: const Offset(0, -33), child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
            GestureDetector(onTap: uploadAvatar, child: CircleUserAvatar(key: ValueKey(avatarVersion), api: widget.api, user: person, radius: 49)),
            const Spacer(),
            OutlinedButton.icon(onPressed: uploadAvatar, icon: const Icon(Icons.photo_camera_outlined, size: 17), label: const Text('Аватар')),
            const SizedBox(width: 9), OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => RewardSettingsScreen(widget.api))), icon: const Icon(Icons.workspace_premium_outlined, size: 17), label: const Text('Награды')),
            const SizedBox(width: 9), FilledButton.icon(onPressed: () => edit(data), icon: const Icon(Icons.edit_outlined, size: 17), label: const Text('Изменить профиль')),
          ])),
          Transform.translate(offset: const Offset(0, -18), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Flexible(child: Text(label(person), style: Theme.of(context).textTheme.headlineMedium)), if (person['verified'] == true) const Padding(padding: EdgeInsets.only(left: 7), child: Icon(Icons.verified, color: circleGold))]),
            const SizedBox(height: 5), Text('@${person['username'] ?? ''}', style: const TextStyle(color: circleGoldBright, fontSize: 13)),
            if ('${data['status_text'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 11), child: Text('${data['status_text']}', style: const TextStyle(fontWeight: FontWeight.w600))),
            if ('${data['bio'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: Text('${data['bio']}')),
          ])),
          const SizedBox(height: 6), Divider(color: Theme.of(context).dividerColor),
          Row(mainAxisAlignment: MainAxisAlignment.spaceAround, children: [
            _counter('${counts['friends'] ?? person['friends_count'] ?? '—'}', 'Друзья'),
            _counter('${counts['posts'] ?? person['posts_count'] ?? '—'}', 'Публикации'),
            _counter('${counts['communities'] ?? person['communities_count'] ?? '—'}', 'Сообщества'),
          ]),
        ])),
      ])),
      const SizedBox(height: 23), const CircleSection(title: 'Публикации', subtitle: 'Мои записи и фотографии'),
      const SizedBox(height: 16), SizedBox(height: 680, child: FeedScreen(widget.api, route: 'profile-posts')),
    ])));
  });
  Widget _counter(String value, String text) => Padding(padding: const EdgeInsets.symmetric(vertical: 10), child: Column(children: [Text(value, style: const TextStyle(color: circleGoldBright, fontSize: 22, fontWeight: FontWeight.w800)), const SizedBox(height: 5), Text(text, style: const TextStyle(color: circleMuted, fontSize: 12))]));
}

class FriendsScreen extends StatelessWidget {
  const FriendsScreen(this.api, {super.key});
  final CircleApi api;
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1100), child: Column(children: [
    const Padding(padding: EdgeInsets.fromLTRB(24, 27, 24, 16), child: CircleSection(title: 'Друзья', subtitle: 'Люди, с которыми ты на связи')),
    Expanded(child: ApiList(api: api, route: 'friends', emptyTitle: 'Пока нет друзей', itemBuilder: (context, person, refresh) => CircleSurface(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14), child: Row(children: [
      CircleUserAvatar(api: api, user: person, radius: 25), const SizedBox(width: 15),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(person), style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 4), Text('@${person['username'] ?? ''}', style: Theme.of(context).textTheme.bodySmall)])),
      OutlinedButton.icon(onPressed: () => Navigator.push(context, MaterialPageRoute<void>(builder: (_) => PublicProfile(api, identifier(person['id'])))), icon: const Icon(Icons.person_outline, size: 16), label: const Text('Профиль')),
    ])))),
  ])));
}
class PublicProfile extends StatelessWidget {
  const PublicProfile(this.api, this.id, {super.key});
  final CircleApi api;
  final int id;
  @override Widget build(BuildContext context) => CirclePage(title: 'Профиль', child: FutureBuilder<Map<String, dynamic>>(
    future: api.call('user-profile', query: {'id': '$id'}),
    builder: (context, snapshot) {
      if (snapshot.hasError) return CircleEmpty(title: 'Профиль недоступен', description: '${snapshot.error}');
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
      final data = snapshot.data!;
      final person = obj(data['user']);
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: Column(children: [
        Padding(padding: const EdgeInsets.all(24), child: CircleSurface(child: Row(children: [CircleUserAvatar(api: api, user: person, radius: 39), const SizedBox(width: 19), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(person), style: Theme.of(context).textTheme.headlineSmall), const SizedBox(height: 4), Text('@${person['username'] ?? ''}', style: const TextStyle(color: circleGoldBright)), if ('${data['bio'] ?? ''}'.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 11), child: Text('${data['bio']}'))]))]))),
        Expanded(child: FeedScreen(api, route: 'profile-posts', query: {'user_id': '$id'})),
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
  @override void initState() {super.initState(); reload();}
  void reload() {conversations = widget.api.call('conversations').then(items);}
  @override Widget build(BuildContext context) {
    final compact = MediaQuery.sizeOf(context).width < 1090;
    return Row(children: [
      SizedBox(width: compact ? 250 : 325, child: Column(children: [
        Container(height: 75, padding: const EdgeInsets.symmetric(horizontal: 21), alignment: Alignment.centerLeft, decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))), child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Сообщения', style: Theme.of(context).textTheme.titleLarge), const SizedBox(height: 5), const Text('Личные переписки', style: TextStyle(color: circleMuted, fontSize: 11))])),
        Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: conversations, builder: (context, snapshot) {
          if (snapshot.hasError) return CircleEmpty(title: 'Нет соединения', description: '${snapshot.error}', action: TextButton(onPressed: () => setState(reload), child: const Text('Повторить')));
          if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
          final data = snapshot.data!;
          if (data.isEmpty) return const CircleEmpty(title: 'Нет диалогов', icon: Icons.forum_outlined);
          return ListView(padding: const EdgeInsets.all(10), children: [for (final conversation in data) Padding(padding: const EdgeInsets.only(bottom: 6), child: InkWell(
            borderRadius: BorderRadius.circular(13), onTap: () => setState(() => selected = conversation), child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 13), decoration: BoxDecoration(color: identifier(selected?['id']) == identifier(conversation['id']) ? circleGold.withValues(alpha: .12) : Colors.transparent, borderRadius: BorderRadius.circular(13), border: Border.all(color: identifier(selected?['id']) == identifier(conversation['id']) ? circleGold.withValues(alpha: .48) : Colors.transparent)),
              child: Row(children: [CircleUserAvatar(api: widget.api, user: obj(conversation['peer']), radius: 21), const SizedBox(width: 11), Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(obj(conversation['peer'])), style: Theme.of(context).textTheme.titleMedium, overflow: TextOverflow.ellipsis), const SizedBox(height: 5), Text('${conversation['last_message'] ?? ''}', style: Theme.of(context).textTheme.bodySmall, maxLines: 1, overflow: TextOverflow.ellipsis)]))]),
            ),
          ))]);
        })),
      ])),
      Container(width: 1, color: Theme.of(context).dividerColor),
      Expanded(child: selected == null ? const CircleEmpty(title: 'Выберите диалог', description: 'Все ваши разговоры — в одном месте.', icon: Icons.forum_outlined) : MessagesScreen(widget.api, identifier(selected!['id']), peer: obj(selected!['peer']), me: widget.me, embedded: true)),
    ]);
  }
}

class MessagesScreen extends StatefulWidget {
  const MessagesScreen(this.api, this.id, {super.key, required this.peer, required this.me, this.embedded = false});
  final CircleApi api;
  final int id;
  final Map<String, dynamic> peer;
  final Map<String, dynamic> me;
  final bool embedded;
  @override State<MessagesScreen> createState() => _MessagesScreenState();
}
class _MessagesScreenState extends State<MessagesScreen> {
  final input = TextEditingController();
  int? reply;
  late Future<List<Map<String, dynamic>>> messages;
  bool sending = false;
  bool recording = false;
  final recorder = AudioRecorder();
  @override void initState() {super.initState(); reload();}
  @override void didUpdateWidget(covariant MessagesScreen old) {super.didUpdateWidget(old); if (old.id != widget.id) {reply = null; reload();}}
  void reload() {messages = widget.api.call('messages', query: {'conversation_id': '${widget.id}'}).then(items);}
  Future<void> send() async {
    final text = input.text.trim();
    if (text.isEmpty || sending) return;
    setState(() => sending = true);
    try {
      await widget.api.call('messages', query: {'conversation_id': '${widget.id}'}, body: {'body': text, 'reply_to_id': reply ?? 0});
      input.clear();
      if (mounted) setState(() {reply = null; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
    finally {if (mounted) setState(() => sending = false);}
  }
  Future<void> attach({bool voice = false}) async {
    final chosen = await FilePicker.platform.pickFiles(type: FileType.custom, allowedExtensions: voice ? ['ogg', 'webm', 'mp3', 'wav', 'm4a'] : ['jpg', 'jpeg', 'png', 'webp', 'gif', 'mp4', 'webm']);
    if (chosen?.files.single.path == null) return;
    try {
      await widget.api.upload('message-upload', File(chosen!.files.single.path!), query: {'conversation_id': '${widget.id}'}, fields: {'kind': voice ? 'VOICE' : 'FILE', 'reply_to_id': '${reply ?? 0}'});
      if (mounted) setState(() {reply = null; reload();});
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> react(int id, String value) async {
    try {
      await widget.api.call('message-reaction', body: {'conversation_id': widget.id, 'message_id': id, 'emoji': value});
      if (mounted) setState(reload);
    } catch (e) {if (mounted) notify(context, '$e');}
  }
  Future<void> startCall({bool video = false}) async {
    try {
      final started = await widget.api.call('mobile-call-start', body: {'conversation_id': widget.id});
      final callId = identifier(started['call_id']);
      if (!mounted || callId < 1) return;
      await Navigator.push(context, MaterialPageRoute<void>(builder: (_) => CircleLiveRoom(
        title: 'Звонок · ${label(widget.peer)}', startVideo: video,
        credentials: () => widget.api.call('mobile-call-token', body: {'conversation_id': widget.id, 'call_id': callId}),
        onFinish: () => widget.api.call('mobile-call-finish', body: {'conversation_id': widget.id, 'call_id': callId}).then((_) {}),
      )));
    } catch (e) {if (mounted) notify(context, 'Звонок недоступен: $e');}
  }
  Future<void> toggleRecording() async {
    if (recording) {
      try {
        final path = await recorder.stop();
        if (mounted) setState(() => recording = false);
        if (path == null) return;
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
      final allowed = await recorder.hasPermission();
      if (!allowed) {if (mounted) notify(context, 'Разрешите доступ к микрофону в настройках Windows'); return;}
      final folder = await getTemporaryDirectory();
      final file = '${folder.path}${Platform.pathSeparator}circle_voice_${DateTime.now().millisecondsSinceEpoch}.wav';
      await recorder.start(const RecordConfig(encoder: AudioEncoder.wav, numChannels: 1, sampleRate: 16000), path: file);
      if (mounted) setState(() => recording = true);
    } catch (e) {if (mounted) notify(context, 'Не удалось включить микрофон: $e');}
  }
  @override void dispose() {if (recording) {recorder.stop();} recorder.dispose(); input.dispose(); super.dispose();}
  @override Widget build(BuildContext context) {
    final chat = Column(children: [
      Container(height: 75, padding: const EdgeInsets.symmetric(horizontal: 20), decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, border: Border(bottom: BorderSide(color: Theme.of(context).dividerColor))), child: Row(children: [
        CircleUserAvatar(api: widget.api, user: widget.peer, radius: 20), const SizedBox(width: 12),
        Expanded(child: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.start, children: [Text(label(widget.peer), style: Theme.of(context).textTheme.titleMedium), Text('@${widget.peer['username'] ?? ''}', style: Theme.of(context).textTheme.bodySmall)])),
        IconButton(tooltip: 'Голосовой звонок', onPressed: () => startCall(), icon: const Icon(Icons.call_outlined, color: circleGold)),
        IconButton(tooltip: 'Видеозвонок', onPressed: () => startCall(video: true), icon: const Icon(Icons.videocam_outlined, color: circleGold)),
        IconButton(tooltip: 'Обновить сообщения', onPressed: () => setState(reload), icon: const Icon(Icons.refresh_rounded)),
      ])),
      Expanded(child: FutureBuilder<List<Map<String, dynamic>>>(future: messages, builder: (context, snapshot) {
        if (snapshot.hasError) return CircleEmpty(title: 'Сообщения не загрузились', description: '${snapshot.error}', action: TextButton(onPressed: () => setState(reload), child: const Text('Повторить')));
        if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
        if (snapshot.data!.isEmpty) return const CircleEmpty(title: 'Начните разговор', description: 'Напишите первое сообщение', icon: Icons.chat_bubble_outline);
        return ListView(padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 20), reverse: true, children: [for (final message in snapshot.data!.reversed) _messageBubble(message)]);
      })),
      if (recording) Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 7), color: circleRed.withValues(alpha: .15), child: const Row(children: [Icon(Icons.fiber_manual_record, size: 14, color: circleRed), SizedBox(width: 8), Text('Идёт запись — нажмите на микрофон, чтобы отправить', style: TextStyle(color: circleRed, fontSize: 12))])),
      if (reply != null) Container(padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 6), color: circleGold.withValues(alpha: .08), child: Row(children: [const Icon(Icons.reply, color: circleGold, size: 17), const SizedBox(width: 7), Expanded(child: Text('Ответ на сообщение #$reply', style: const TextStyle(fontSize: 12))), IconButton(onPressed: () => setState(() => reply = null), icon: const Icon(Icons.close, size: 18))])),
      Container(padding: const EdgeInsets.all(15), decoration: BoxDecoration(color: Theme.of(context).cardTheme.color, border: Border(top: BorderSide(color: Theme.of(context).dividerColor))), child: Row(children: [
        IconButton(tooltip: 'Прикрепить фото / видео', onPressed: () => attach(), icon: const Icon(Icons.attach_file, color: circleGold)),
        IconButton(tooltip: recording ? 'Остановить и отправить голосовое сообщение' : 'Записать голосовое сообщение', onPressed: toggleRecording, icon: Icon(recording ? Icons.stop_circle_outlined : Icons.mic_none_outlined, color: recording ? circleRed : circleGold)),
        IconButton(tooltip: 'Прикрепить аудиофайл', onPressed: () => attach(voice: true), icon: const Icon(Icons.audio_file_outlined, color: circleGold)),
        const SizedBox(width: 7), Expanded(child: TextField(controller: input, minLines: 1, maxLines: 4, maxLength: 10000, onSubmitted: (_) => send(), decoration: const InputDecoration(hintText: 'Написать сообщение...', counterText: ''))),
        const SizedBox(width: 9), IconButton(tooltip: 'Отправить', onPressed: sending ? null : send, icon: const Icon(Icons.send_rounded, color: circleGold, size: 24)),
      ])),
    ]);
    return widget.embedded ? chat : CirclePage(title: label(widget.peer), child: chat);
  }
  Widget _messageBubble(Map<String, dynamic> message) {
    final mine = identifier(message['user_id']) == identifier(widget.me['id']);
    final attachments = (message['attachments'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
    final id = identifier(message['id']);
    return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 520), child: Padding(padding: const EdgeInsets.only(bottom: 12), child: Container(
      padding: const EdgeInsets.fromLTRB(16, 11, 12, 8), decoration: BoxDecoration(color: mine ? circleGold.withValues(alpha: .12) : Theme.of(context).cardTheme.color,
        border: Border.all(color: mine ? circleGold.withValues(alpha: .28) : Theme.of(context).dividerColor), borderRadius: BorderRadius.circular(15)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (message['reply_to_id'] != null) Container(margin: const EdgeInsets.only(bottom: 8), padding: const EdgeInsets.all(8), decoration: BoxDecoration(color: circleGold.withValues(alpha: .08), borderRadius: BorderRadius.circular(7)), child: Text('↳ ${message['reply_body'] ?? 'Ответ на сообщение'}', style: const TextStyle(color: circleGoldBright, fontSize: 12), maxLines: 3)),
        if ('${message['body'] ?? ''}'.isNotEmpty) SelectableText('${message['body']}', style: const TextStyle(fontSize: 13.5, height: 1.5)),
        for (final attachment in attachments) Padding(padding: const EdgeInsets.only(top: 10), child: CircleMedia(api: widget.api, route: 'attachment', id: identifier(attachment['id']), mime: '${attachment['mime'] ?? ''}', compact: true)),
        Row(mainAxisSize: MainAxisSize.min, children: [Text(circleDate(message['created_at']), style: const TextStyle(color: circleMuted, fontSize: 10)), const SizedBox(width: 9), PopupMenuButton<String>(tooltip: 'Действия с сообщением', icon: const Icon(Icons.more_horiz, size: 18), padding: EdgeInsets.zero,
          onSelected: (value) {if (value == 'reply') {setState(() => reply = id);} else {react(id, value);}},
          itemBuilder: (_) => [const PopupMenuItem(value: 'reply', child: Text('Ответить')), ...['❤️', '👍', '😂', '🔥', '👏'].map((reaction) => PopupMenuItem(value: reaction, child: Text(reaction)))],
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
    Padding(padding: const EdgeInsets.fromLTRB(24, 26, 24, 18), child: CircleSection(title: 'Мои сообщества', subtitle: 'Пространства, в которые тебя пригласили', trailing: FilledButton.icon(onPressed: join, icon: const Icon(Icons.link, size: 19), label: const Text('Вступить по ссылке')))),
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
    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
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
            if (['OWNER', 'ADMIN'].contains('${community['role'] ?? ''}'.toUpperCase())) OutlinedButton.icon(onPressed: () => manage(community), icon: const Icon(Icons.settings_outlined), label: const Text('Управление')),
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
  @override Widget build(BuildContext context) => CirclePage(title: '# ${widget.name}', child: Column(children: [
    Expanded(child: ApiList(key: ValueKey(reload), api: widget.api, route: 'channel-messages', query: {'channel_id': '${widget.id}'}, emptyTitle: 'В канале пока тихо', itemBuilder: (context, message, refresh) => CircleSurface(padding: const EdgeInsets.all(14), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      CircleUserAvatar(api: widget.api, user: obj(message['author']), radius: 20), const SizedBox(width: 12),
      Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(label(obj(message['author'])), style: const TextStyle(fontWeight: FontWeight.w700))), Text(circleDate(message['created_at']), style: const TextStyle(color: circleMuted, fontSize: 11))]),
        if (message['reply_to_id'] != null) Text('↳ Ответ на #${message['reply_to_id']}', style: const TextStyle(fontSize: 11, color: circleGold)),
        const SizedBox(height: 6), Text('${message['body'] ?? ''}'),
        Wrap(children: [TextButton(onPressed: () => setState(() => reply = identifier(message['id'])), child: const Text('Ответить')), for (final reaction in ['❤️', '👍', '😂']) TextButton(onPressed: () async {try {await widget.api.call('channel-react', body: {'message_id': identifier(message['id']), 'emoji': reaction}); if (context.mounted) refresh();} catch (e) {if (context.mounted) notify(context, '$e');}}, child: Text(reaction))]),
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
    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
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
  const UpdatesScreen({super.key});
  @override State<UpdatesScreen> createState() => _UpdatesScreenState();
}
class _UpdatesScreenState extends State<UpdatesScreen> {
  bool busy = false;
  String status = 'Обновления проверяются по подписанному манифесту Circle.';
  Future<void> check() async {
    if (updateManifest.isEmpty || updatePublicKey.isEmpty) {
      setState(() => status = 'Канал обновлений ещё не настроен. Укажите CIRCLE_UPDATE_URL и CIRCLE_UPDATE_PUBLIC_KEY при сборке.');
      return;
    }
    setState(() {busy = true; status = 'Проверяю наличие обновлений...';});
    final updater = CircleUpdater(manifestUrl: Uri.parse(updateManifest), publicKeyBase64: updatePublicKey);
    try {
      final release = await updater.check(appVersion);
      if (release == null) {if (mounted) setState(() => status = 'Установлена актуальная версия $appVersion'); return;}
      if (!mounted) return;
      final consent = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: Text('Обновление ${release.version}'), content: const Text('Скачать и проверить установщик Circle?'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Скачать'))]));
      if (consent != true) return;
      if (mounted) setState(() => status = 'Скачиваю установщик и проверяю SHA-256...');
      final file = await updater.downloadVerified(release);
      if (!mounted) return;
      setState(() => status = 'Установщик проверен: ${file.path}');
      final launch = await showDialog<bool>(context: context, builder: (c) => AlertDialog(title: const Text('Новая версия готова'), content: const Text('Запустить обновление? Текущий сеанс будет закрыт.'), actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Позже')), FilledButton(onPressed: () => Navigator.pop(c, true), child: const Text('Установить'))]));
      if (launch == true) {await Process.start(file.path, [], mode: ProcessStartMode.detached); await windowManager.close();}
    } catch (e) {if (mounted) setState(() => status = 'Ошибка обновления: $e');}
    finally {updater.close(); if (mounted) setState(() => busy = false);}
  }
  @override Widget build(BuildContext context) => Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 650), child: Padding(padding: const EdgeInsets.all(25), child: CircleSurface(padding: const EdgeInsets.all(35), accent: true, child: Column(mainAxisSize: MainAxisSize.min, children: [
    Container(padding: const EdgeInsets.all(20), decoration: BoxDecoration(shape: BoxShape.circle, color: circleGold.withValues(alpha: .12)), child: const Icon(Icons.system_update_alt, size: 36, color: circleGold)),
    const SizedBox(height: 18), Text('Circle для Windows', style: Theme.of(context).textTheme.headlineSmall),
    const SizedBox(height: 7), const Text('Версия $appVersion', style: TextStyle(color: circleGoldBright)),
    const SizedBox(height: 20), Text(status, style: const TextStyle(color: circleMuted), textAlign: TextAlign.center),
    const SizedBox(height: 25), FilledButton.icon(onPressed: busy ? null : check, icon: const Icon(Icons.refresh), label: Text(busy ? 'Проверка...' : 'Проверить обновления')),
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
      if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
      final summary = snapshot.data!;
      final cases = (summary['cases'] as List? ?? []).whereType<Map>().toList();
      return Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 1000), child: ListView(padding: const EdgeInsets.all(24), children: [
        const CircleSection(title: 'Панель администратора', subtitle: 'Обзор пользователей и заявок на проверку'),
        const SizedBox(height: 20), Row(children: [Expanded(child: CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('Пользователи', style: TextStyle(color: circleMuted)), const SizedBox(height: 8), Text('${summary['users'] ?? '—'}', style: Theme.of(context).textTheme.headlineMedium)]))), const SizedBox(width: 13), Expanded(child: CircleSurface(accent: true, child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [const Text('На модерации', style: TextStyle(color: circleMuted)), const SizedBox(height: 8), Text('${summary['pending'] ?? '—'}', style: Theme.of(context).textTheme.headlineMedium)])))]),
        const SizedBox(height: 24), const CircleSection(title: 'Ожидают проверки'), const SizedBox(height: 12),
        if (cases.isEmpty) const CircleSurface(child: Text('Новых заявок нет')),
        for (final item in cases) Padding(padding: const EdgeInsets.only(bottom: 10), child: CircleSurface(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Заявка #${item['id']} · ${item['source_type'] ?? ''}', style: const TextStyle(color: circleGold, fontWeight: FontWeight.w700)), const SizedBox(height: 7), Text('${item['excerpt'] ?? ''}'), const SizedBox(height: 6), Text('Пользователь: ${item['username'] ?? ''}', style: const TextStyle(color: circleMuted, fontSize: 12))]))),
        const SizedBox(height: 12), const Text('Полный набор действий модерации пока доступен только в веб-версии: Mobile API 5.2.3 возвращает сводку, но не предоставляет защищённые методы обработки заявок.', style: TextStyle(fontSize: 12, color: circleMuted)),
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
    if (!snapshot.hasData) return const Center(child: CircularProgressIndicator(color: circleGold));
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
