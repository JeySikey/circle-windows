import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';
import 'package:circle_windows/desktop_notifications.dart';
import 'package:circle_windows/notification_models.dart';

class FakeApi extends CircleApi {
  FakeApi():super('https://acircle.ru');
  final events = <Map<String, dynamic>>[];
  int reads = 0;
  int directReads = 0;
  @override Future<Map<String, dynamic>> call(String route,
      {Map<String, String> query = const {}, Map<String, dynamic>? body, bool auth = true}) async {
    if (route == 'notification-settings') return {'ok': true, 'settings': {'messages': true}};
    if (route == 'notification-read') { reads++; return {'ok': true}; }
    if (route == 'notification-one') {directReads++; return {'ok': true,
        'notification': events.firstWhere((e) => e['id'] == int.parse(query['id']!))};}
    if (route == 'notifications') {
      final after = int.tryParse(query['after'] ?? '') ?? 0;
      return {'ok': true, 'items': events.where((e) => (e['id'] as int) > after).toList(),
        'unread': events.where((e) => e['read'] != true).length};
    }
    throw StateError('Unexpected route $route');
  }
}
class FakeStore implements CircleNotificationStore {
  final map = <String, String>{};
  @override Future<String?> read(String key) async => map[key];
  @override Future<void> write(String key, String value) async {map[key] = value;}
}
class FakeToast implements CircleToastBridge {
  final events = <CircleEvent>[];
  final soundFlags = <bool>[];
  @override Future<void> initialize(void Function(int) onClick) async {}
  @override Future<void> show(CircleEvent event, {required bool sound}) async {
    events.add(event); soundFlags.add(sound);
  }
}
void main() {
  test('first poll baselines history; new events toast once with sound', () async {
    final api = FakeApi()..events.add({'id': 5, 'kind': 'dm_message',
      'payload': {'conversation_id': 1}, 'read': false});
    final bridge = FakeToast();
    final store = FakeStore();
    final opened = <int>[];
    final notifications = CircleNotifications(api: api, userId: 12,
      bridge: bridge, store: store,
      pollInterval: const Duration(days: 1),
      onOpen: (event) async => opened.add(event.id));
    await notifications.start();
    expect(bridge.events, isEmpty); // no noisy initial history replay
    expect(notifications.unread.value, 1);
    api.events.add({'id': 6, 'kind': 'post_comment', 'read': false,
      'payload': {'post_id': 42}});
    await notifications.checkNow();
    await notifications.checkNow();
    expect(bridge.events.map((e) => e.id).toList(), [6]);
    expect(bridge.soundFlags, [true]);
    await notifications.activate(6);
    expect(opened, [6]);
    expect(api.reads, 1);
    await notifications.setSound(false);
    api.events.add({'id': 7, 'kind': 'dm_message', 'read': false,
      'payload': {'conversation_id': 4}});
    await notifications.checkNow();
    expect(bridge.soundFlags, [true, false]);
    notifications.dispose();
  });

  test('old Windows notification activation resolves only through user-scoped API', () async {
    final api = FakeApi()..events.add({'id': 37, 'kind': 'dm_message',
      'read': false, 'payload': {'conversation_id': 20}});
    final bridge = FakeToast();
    final opened = <CircleNotificationDestination>[];
    final service = CircleNotifications(api: api, userId: 12,
      bridge: bridge, store: FakeStore(),
      onOpen: (event) async => opened.add(event.target.destination));
    await service.start();
    // A notification from the Windows Action Center might no longer be cached.
    final anotherService = CircleNotifications(api: api, userId: 12,
      bridge: FakeToast(), store: FakeStore(),
      onOpen: (event) async => opened.add(event.target.destination));
    await anotherService.start();
    api.events.add({'id': 38, 'kind': 'dm_message', 'read': false,
      'payload': {'conversation_id': 21}});
    await anotherService.activate(38);
    expect(api.directReads, 1);
    expect(opened, [CircleNotificationDestination.conversation]);
    service.dispose();
    anotherService.dispose();
  });

  test('preferences are isolated per account/server and persist locally', () async {
    final api = FakeApi(); final store = FakeStore();
    final a = CircleNotifications(api: api, userId: 1, store: store,
      bridge: FakeToast(), onOpen: (_) async {});
    await a.start();
    await a.setEnabled(false);
    a.dispose();
    final aAgain = CircleNotifications(api: api, userId: 1, store: store,
      bridge: FakeToast(), onOpen: (_) async {});
    await aAgain.start();
    expect(aAgain.enabled.value, false);
    aAgain.dispose();
    final b = CircleNotifications(api: api, userId: 2, store: store,
      bridge: FakeToast(), onOpen: (_) async {});
    await b.start();
    expect(b.enabled.value, true);
    b.dispose();
  });
}
