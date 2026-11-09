import 'dart:convert';
import 'dart:io';
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
      if (response.statusCode >= 400 || decoded['ok'] != true) throw CircleError('${decoded['message'] ?? decoded['error'] ?? 'HTTP ${response.statusCode}'}');
      return decoded;
    } on CircleError { rethrow; } on SocketException { throw CircleError('Нет соединения с сервером');
    } on FormatException { throw CircleError('Сервер вернул не-JSON ответ');
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
  Future<List<int>> media(String route, int id) async {
    final r = await _client.get(uri(route, {'id':'$id'}), headers: {'Authorization':'Bearer $token'}).timeout(const Duration(seconds: 45));
    if (r.statusCode != 200) throw CircleError('Медиа недоступно: ${r.statusCode}');
    return r.bodyBytes;
  }
  void dispose() => _client.close();
}

List<Map<String, dynamic>> items(Map<String, dynamic> value) => (value['items'] as List? ?? []).whereType<Map>().map((e) => Map<String, dynamic>.from(e)).toList();
Map<String, dynamic> obj(dynamic value) => value is Map ? Map<String, dynamic>.from(value) : {};
String label(Map<String, dynamic> value) => '${value['display_name'] ?? value['name'] ?? value['username'] ?? 'Пользователь'}';
int identifier(dynamic x) => x is int ? x : int.tryParse('$x') ?? 0;
