import 'dart:convert';
import 'dart:io';
import 'dart:async';
import 'package:http/http.dart' as http;

class CircleError implements Exception {
  CircleError(this.message);
  final String message;
  @override String toString() => message;
}

class CircleApi {
  CircleApi(String origin) : base = Uri.parse(origin) {
    if (base.scheme != 'https' || base.host.isEmpty || base.userInfo.isNotEmpty || base.hasQuery || base.hasFragment || (base.path != '' && base.path != '/')) {
      throw CircleError('Укажите HTTPS-адрес сервера без пути и параметров');
    }
  }
  final Uri base;
  String? token;
  final http.Client _client = http.Client();
  // Avatars / profile cover: coalesced requests and a bounded in-memory LRU.
  // Never cache messages or video files; prevents memory growth and scroll jank.
  final Map<String, Future<List<int>>> _imageCache = {};
  final Map<String, int> _imageSizes = {};
  int _imageBytes = 0;
  void _evictMedia(String key) {
    _imageCache.remove(key);
    _imageBytes -= _imageSizes.remove(key) ?? 0;
    if (_imageBytes < 0) _imageBytes = 0;
  }
  void clearMedia([String? route]) {
    if (route == null) {_imageCache.clear(); _imageSizes.clear(); _imageBytes = 0; return;}
    for (final key in _imageCache.keys.where((key) => key.startsWith('$route:')).toList()) {_evictMedia(key);}
  }
  Uri uri(String route, [Map<String, String> query = const {}]) => base.replace(path: '/api/mobile.php', queryParameters: {'route': route, ...query});

  Future<Map<String, dynamic>> call(String route, {Map<String, String> query = const {}, Map<String, dynamic>? body, bool auth = true}) async {
    final headers = <String, String>{'Accept':'application/json'};
    if (auth) {
      if (token == null) throw CircleError('Требуется вход в аккаунт');
      headers['Authorization'] = 'Bearer $token';
    }
    try {
      final response = body == null
          ? await _client.get(uri(route, query), headers: headers).timeout(const Duration(seconds: 25))
          : await _client.post(uri(route, query), headers: {...headers, 'Content-Type': 'application/json'}, body: jsonEncode(body)).timeout(const Duration(seconds: 25));
      final decoded = jsonDecode(utf8.decode(response.bodyBytes));
      if (decoded is! Map<String, dynamic>) throw CircleError('Некорректный ответ сервера');
      if (response.statusCode >= 400 || decoded['ok'] != true) {
        final code = '${decoded['error'] ?? ''}';
        final hint = switch (code) {
          'SERVER_ERROR' => 'Внутренняя ошибка сервера Circle. Проверьте совместимость Mobile API и журнал ошибок PHP.',
          'UNAUTHORIZED' => 'Сессия истекла. Войдите заново.',
          'FEATURE_DISABLED' => 'Эта функция отключена администратором сайта.',
          'FORBIDDEN' => 'Недостаточно прав для этого действия.',
          'RATE_LIMIT' => 'Слишком много запросов. Повторите позже.',
          _ => '${decoded['message'] ?? decoded['error'] ?? 'HTTP ${response.statusCode}'}',
        };
        throw CircleError(hint);
      }
      return decoded;
    } on CircleError { rethrow;
    } on TimeoutException { throw CircleError('Сервер долго не отвечает. Проверьте подключение.');
    } on SocketException { throw CircleError('Нет соединения с сервером');
    } on FormatException { throw CircleError('Сервер вернул некорректный JSON');
    } catch (e) { throw CircleError('Ошибка запроса: $e'); }
  }

  Future<Map<String, dynamic>> upload(String route, File file, {Map<String, String> query = const {}, Map<String, String> fields = const {}, String field = 'attachment'}) async {
    if (token == null) throw CircleError('Требуется вход');
    final req = http.MultipartRequest('POST', uri(route, query))
      ..headers['Authorization'] = 'Bearer $token'
      ..fields.addAll(fields)
      ..files.add(await http.MultipartFile.fromPath(field, file.path));
    final result = await http.Response.fromStream(await _client.send(req).timeout(const Duration(seconds: 120)));
    final payload = jsonDecode(utf8.decode(result.bodyBytes));
    if (payload is! Map<String, dynamic> || payload['ok'] != true || result.statusCode >= 400) throw CircleError('${payload is Map ? payload['error'] : result.statusCode}');
    return payload;
  }

  // Media endpoints require bearer authorization; never expose the token in URLs.
  Future<List<int>> media(String route, int id) {
    if (token == null) return Future.error(CircleError('Требуется вход в аккаунт'));
    final cacheable = {'avatar', 'profile-cover', 'community-icon', 'community-banner'}.contains(route);
    final key = '$route:$id';
    if (cacheable && _imageCache.containsKey(key)) {
      // Move recently visited avatars to the end, so eviction is true LRU.
      final cached = _imageCache.remove(key)!;
      _imageCache[key] = cached;
      return cached;
    }
    final request = _client.get(uri(route, {'id': '$id'}),
        headers: {'Authorization': 'Bearer $token'}).timeout(const Duration(seconds: 45)).then((r) {
      if (r.statusCode != 200) throw CircleError('Медиа недоступно: HTTP ${r.statusCode}');
      if (r.bodyBytes.length > 12 * 1024 * 1024 && cacheable) {
        throw CircleError('Изображение слишком большое');
      }
      return r.bodyBytes;
    });
    if (cacheable) {
      while (_imageCache.length >= 36) {_evictMedia(_imageCache.keys.first);}
      _imageCache[key] = request;
      request.then((bytes) {
        if (!identical(_imageCache[key], request)) return;
        _imageSizes[key] = bytes.length;
        _imageBytes += bytes.length;
        while (_imageBytes > 32 * 1024 * 1024 && _imageCache.isNotEmpty) {
          _evictMedia(_imageCache.keys.first);
        }
      }, onError: (Object _) { if (identical(_imageCache[key], request)) _evictMedia(key); });
    }
    return request;
  }
  /// Stream large audio/video attachments directly to disk instead of buffering
  /// every clip in RAM while scrolling the feed or messages.
  Future<void> downloadMediaToFile(String route, int id, File destination,
      {int maxBytes = 200 * 1024 * 1024}) async {
    if (token == null) throw CircleError('Требуется вход в аккаунт');
    final request = http.Request('GET', uri(route, {'id': '$id'}))
      ..headers['Authorization'] = 'Bearer $token';
    final response = await _client.send(request).timeout(const Duration(seconds: 35));
    if (response.statusCode != 200) {
      await response.stream.drain<void>();
      throw CircleError('Не удалось загрузить медиа: HTTP ${response.statusCode}');
    }
    final sink = destination.openWrite();
    var received = 0;
    try {
      await for (final chunk in response.stream.timeout(const Duration(seconds: 60))) {
        received += chunk.length;
        if (received > maxBytes) throw CircleError('Медиафайл превышает допустимый размер');
        sink.add(chunk);
      }
    } catch (_) {
      await sink.close();
      try { await destination.delete(); } catch (_) {}
      rethrow;
    }
    await sink.close();
    if (received == 0) throw CircleError('Медиафайл пуст');
  }
  void dispose() { _imageCache.clear(); _client.close(); }
}

List<Map<String, dynamic>> items(Map<String, dynamic> value) => (value['items'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
Map<String, dynamic> obj(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : {};
String label(Map<String, dynamic> value) => '${value['display_name'] ?? value['name'] ?? value['username'] ?? 'Пользователь'}';
int identifier(dynamic x) => x is int ? x : int.tryParse('$x') ?? 0;
