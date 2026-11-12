import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter_desktop_notifications/flutter_desktop_notifications.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'api.dart';
import 'notification_models.dart';

/// App notifications work while Circle's Windows process is alive, including
/// when the window is minimized. True push while fully exited requires a
/// separately registered background service (not implemented by polling).
abstract class CircleToastBridge {
  Future<void> initialize(void Function(int id) onClick);
  Future<void> show(CircleEvent event, {required bool sound});
}

class WindowsCircleToasts implements CircleToastBridge {
  static const appId = 'ru.acircle.circle.windows';
  final DesktopNotifier notifier = DesktopNotifier(appName: 'Circle', appId: appId);
  final WindowsNotification windows = WindowsNotification(applicationId: appId);

  @override
  Future<void> initialize(void Function(int id) onClick) async {
    if (!Platform.isWindows) return;
    await WindowsNotification.registerAumid(aumid: appId, displayName: 'Circle');
    await notifier.requestPermission();
    await notifier.setCallback((details) {
      if (details.event != NotificationEvent.activated) return;
      final raw = details.arguments ?? details.message.id;
      final id = int.tryParse(raw.replaceFirst('circle:event:', '').replaceFirst('circle-', '')) ?? 0;
      if (id < 1) return;
      WindowsNotification.bringAppToForeground();
      onClick(id);
    });
  }

  @override
  Future<void> show(CircleEvent event, {required bool sound}) async {
    if (!Platform.isWindows) return;
    await windows.showNotificationPluginTemplate(
      NotificationMessage.fromPluginTemplate(
        'circle-${event.id}', event.heading, event.summary,
        launch: 'circle:event:${event.id}',
        audio: sound
            ? NotificationAudio(sound: event.kind == 'dm_call' ? NotificationSound.Call : NotificationSound.IM)
            : const NotificationAudio.silent(),
      ),
    );
  }
}

abstract class CircleNotificationStore {
  Future<String?> read(String key);
  Future<void> write(String key, String value);
}

class CircleSecureNotificationStore implements CircleNotificationStore {
  const CircleSecureNotificationStore();
  static const _storage = FlutterSecureStorage();
  @override Future<String?> read(String key) => _storage.read(key: key);
  @override Future<void> write(String key, String value) => _storage.write(key: key, value: value);
}

/// Serialized bounded polling, persistent last-seen cursor, per-user settings.
/// No API or secret token ever reaches a Windows toast or protocol URL.
class CircleNotifications {
  CircleNotifications({required this.api, required this.userId,
    required this.onOpen, CircleToastBridge? bridge,
    CircleNotificationStore? store, this.pollInterval = const Duration(seconds: 18)})
      : bridge = bridge ?? WindowsCircleToasts(),
        store = store ?? const CircleSecureNotificationStore();

  final CircleApi api;
  final int userId;
  final Future<void> Function(CircleEvent) onOpen;
  final CircleToastBridge bridge;
  final CircleNotificationStore store;
  final Duration pollInterval;
  final unread = ValueNotifier<int>(0);
  final enabled = ValueNotifier<bool>(true);
  final soundEnabled = ValueNotifier<bool>(true);
  bool _active = false;
  bool _busy = false;
  bool _nativeReady = false;
  int _cursor = 0;
  Timer? _timer;
  final Map<int, CircleEvent> _recent = {};
  Map<String, bool> _categoryPermissions = {};
  String get _prefix => 'circle_notifications_${api.base.host}_$userId';

  Future<void> start() async {
    if (_active) return;
    _active = true;
    try {
      final previousCursor = int.tryParse(await store.read('${_prefix}_cursor') ?? '') ?? 0;
      final storedEnabled = await store.read('${_prefix}_enabled');
      final storedSound = await store.read('${_prefix}_sound');
      if (!_active) return;
      _cursor = previousCursor;
      enabled.value = storedEnabled != '0';
      soundEnabled.value = storedSound != '0';
    } catch (_) { /* Private storage can be unavailable temporarily. */ }
    try {
      final response = await api.call('notification-settings');
      final settings = response['settings'];
      if (settings is Map) {
        _categoryPermissions = {
          for (final entry in settings.entries)
            '${entry.key}': entry.value == true,
        };
      }
    } catch (_) { /* Older API: notifications are still shown. */ }
    if (!_active) return;
    try {
      await bridge.initialize((id) => unawaited(activate(id)));
      _nativeReady = true;
    } catch (e) {
      debugPrint('Circle toast initialization: $e');
      _nativeReady = false;
    }
    if (!_active) return;
    await checkNow();
    if (_active) _timer = Timer.periodic(pollInterval, (_) => unawaited(checkNow()));
  }

  Future<void> setEnabled(bool state) async {
    enabled.value = state;
    try { await store.write('${_prefix}_enabled', state ? '1' : '0'); } catch (_) {}
  }
  Future<void> setSound(bool state) async {
    soundEnabled.value = state;
    try { await store.write('${_prefix}_sound', state ? '1' : '0'); } catch (_) {}
  }

  bool _categoryAllowed(CircleEvent event) => switch(event.category) {
    'posts' => _categoryPermissions['communities'] != false,
    final category => _categoryPermissions[category] != false,
  };

  Future<void> checkNow() async {
    if (!_active || _busy) return;
    _busy = true;
    try {
      var after = _cursor;
      final initial = after == 0;
      var maxObserved = after;
      var remaining = 3; // at most 120 items per poll, never unbounded.
      final pending = <CircleEvent>[];
      do {
        final response = await api.call('notifications', query: after > 0 ? {'after': '$after'} : {});
        if (!_active) return;
        unread.value = (response['unread'] as num?)?.toInt() ?? 0;
        final batch = items(response).map(CircleEvent.fromJson).where((e) => e.id > 0).toList();
        if (batch.isEmpty) break;
        for (final item in batch) {
          _recent[item.id] = item;
          if (_recent.length > 160) _recent.remove(_recent.keys.first);
          if (item.id > maxObserved) maxObserved = item.id;
          if (!initial && item.id > _cursor && !item.read) pending.add(item);
        }
        // A server without `after` returns descending pages. Stop to avoid
        // reprocessing the same 40 notifications, while still deduplicating.
        if (batch.length < 40 || after == 0 || batch.any((item) => item.id <= after)) break;
        final next = batch.map((e) => e.id).reduce((a, b) => a > b ? a : b);
        if (next <= after) break;
        after = next;
      } while (--remaining > 0);

      if (maxObserved > _cursor) {
        _cursor = maxObserved;
        try { await store.write('${_prefix}_cursor', '$_cursor'); } catch (_) {}
      }
      if (!initial && enabled.value && _nativeReady) {
        pending.sort((a,b) => a.id.compareTo(b.id));
        // Avoid a wall of toasts after returning from a long offline period.
        for (final item in pending.length > 5 ? pending.sublist(pending.length - 5) : pending) {
          if (!_active || !_categoryAllowed(item)) continue;
          try { await bridge.show(item, sound: soundEnabled.value); }
          catch (e) { debugPrint('Circle toast delivery: $e'); }
        }
      }
    } catch (e) {
      // Transient connection errors never clear the cursor or session.
      debugPrint('Circle notification poll: $e');
    } finally { _busy = false; }
  }

  Future<void> activate(int id) async {
    if (!_active || id < 1) return;
    var event = _recent[id];
    if (event == null) {
      // Windows Action Center retains events longer than our in-memory cache.
      // Fetch only the exact event for this authenticated user; avoid scanning
      // the last 40 events and accidentally skipping an older toast.
      try {
        final response = await api.call('notification-one', query: {'id': '$id'});
        final raw = response['notification'];
        if (raw is Map) event = CircleEvent.fromJson(Map<String, dynamic>.from(raw));
      } catch (_) { /* The event may have been deleted or access revoked. */ }
    }
    if (event == null || !_active) return;
    try {
      await api.call('notification-read', body: {'id': id});
      if (unread.value > 0) unread.value--;
    } catch (_) {}
    if (_active) await onOpen(event);
  }

  Future<void> markAllRead() async {
    await api.call('notification-read', body: {'id': 0});
    unread.value = 0;
  }

  void dispose() {
    _active = false;
    _timer?.cancel();
    _timer = null;
    _recent.clear();
    unread.dispose();
    enabled.dispose();
    soundEnabled.dispose();
  }
}
