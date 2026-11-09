import 'dart:convert';
import 'dart:io';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  const UpdateInfo(this.version, this.download, this.sha256);
  final String version;
  final Uri download;
  final String sha256;
}

class CircleUpdater {
  CircleUpdater({required this.manifestUrl, required this.publicKeyBase64, http.Client? client}) : _client = client ?? http.Client();
  final Uri manifestUrl;
  final String publicKeyBase64;
  final http.Client _client;
  void close() => _client.close();

  static bool newer(String candidate, String current) {
    final pattern = RegExp(r'^\d+\.\d+\.\d+$');
    if (!pattern.hasMatch(candidate) || !pattern.hasMatch(current)) return false;
    final a = candidate.split('.').map(int.parse).toList();
    final b = current.split('.').map(int.parse).toList();
    for (var i = 0; i < 3; i++) {
      if (a[i] > b[i]) return true;
      if (a[i] < b[i]) return false;
    }
    return false;
  }

  Future<UpdateInfo?> check(String currentVersion) async {
    if (manifestUrl.scheme != 'https' || manifestUrl.userInfo.isNotEmpty || publicKeyBase64.isEmpty) {
      throw StateError('Update source and verification key must be configured');
    }
    final response = await _client.get(manifestUrl).timeout(const Duration(seconds: 15));
    if (response.statusCode != 200 || response.bodyBytes.length > 32768) throw const FormatException('Invalid update manifest');
    final envelope = jsonDecode(utf8.decode(response.bodyBytes));
    if (envelope is! Map<String, dynamic> || envelope['payload'] is! String || envelope['signature'] is! String) {
      throw const FormatException('Malformed signed manifest');
    }
    final raw = base64Decode(envelope['payload'] as String);
    final sig = base64Decode(envelope['signature'] as String);
    final pub = base64Decode(publicKeyBase64);
    if (raw.length > 8192 || sig.length != 64 || pub.length != 32) throw const FormatException('Invalid signature lengths');
    final verified = await Ed25519().verify(raw, signature: Signature(sig, publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)));
    if (!verified) throw const FormatException('Update signature verification failed');
    final data = jsonDecode(utf8.decode(raw));
    if (data is! Map<String, dynamic>) throw const FormatException('Malformed update payload');
    final version = data['version'];
    final download = Uri.tryParse('${data['download_url'] ?? ''}');
    final sha = data['sha256'];
    if (version is! String || download == null || download.scheme != 'https' || !download.path.toLowerCase().endsWith('.exe') || download.userInfo.isNotEmpty ||
        download.hasFragment || sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const FormatException('Unsafe update metadata');
    }
    if (!newer(version, currentVersion)) return null;
    return UpdateInfo(version, download, sha);
  }

  Future<File> downloadVerified(UpdateInfo info) async {
    final dir = await getTemporaryDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}circle-${info.version}.exe');
    final partial = File('${target.path}.part');
    try {
      final request = http.Request('GET', info.download)..followRedirects = false;
      final response = await _client.send(request).timeout(const Duration(seconds: 25));
      if (response.statusCode != 200) throw StateError('Download HTTP ${response.statusCode}');
      final sink = partial.openWrite();
      var total = 0;
      try {
        await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
          total += chunk.length;
          if (total > 250 * 1024 * 1024) throw const FormatException('Update is larger than 250 MiB');
          sink.add(chunk);
        }
      } finally {
        await sink.close();
      }
      final hash = await Sha256().hashStream(partial.openRead());
      final digest = hash.bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
      if (digest != info.sha256) throw const FormatException('Update checksum mismatch');
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }
}
