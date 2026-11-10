import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';

/// Complete Flutter Windows payload, NOT an executable installer.
/// The separately launched updater atomically swaps the application directory.
class UpdateInfo {
  const UpdateInfo(this.version, this.download, this.sha256, {this.notes = ''});
  final String version;
  final Uri download;
  final String sha256;
  final String notes;
}

class CircleUpdater {
  CircleUpdater({required this.manifestUrl, required this.publicKeyBase64, http.Client? client})
      : _client = client ?? http.Client();

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
      if (a[i] != b[i]) return a[i] > b[i];
    }
    return false;
  }

  static Uri? githubManifestUri(String repository) {
    if (!RegExp(r'^[a-zA-Z0-9_.-]+/[a-zA-Z0-9_.-]+$').hasMatch(repository) ||
        repository.contains('..')) return null;
    return Uri.https('github.com', '/$repository/releases/latest/download/update-manifest.json');
  }

  /// All update manifests are authenticated using a pinned Ed25519 public key
  /// embedded in the installed application during GitHub Actions build.
  Future<UpdateInfo?> check(String currentVersion) async {
    if (manifestUrl.scheme != 'https' || manifestUrl.userInfo.isNotEmpty ||
        publicKeyBase64.isEmpty) {
      throw StateError('Подписанный канал обновлений не настроен.');
    }
    final response = await _client.get(manifestUrl).timeout(const Duration(seconds: 15));
    if (response.statusCode == 404) {
      // A missing Release or manifest is NOT proof that the installed version
      // is current. GitHub Actions artifacts are not published Releases.
      throw StateError('На GitHub не найден опубликованный релиз с update-manifest.json (HTTP 404). Проверьте Releases, публичный доступ и версию релиза.');
    }
    if (response.statusCode != 200 || response.bodyBytes.length > 32768) {
      throw StateError('GitHub не отдал манифест обновлений (HTTP ${response.statusCode}).');
    }
    final envelope = jsonDecode(utf8.decode(response.bodyBytes));
    if (envelope is! Map<String, dynamic> ||
        envelope['payload'] is! String || envelope['signature'] is! String) {
      throw const FormatException('Некорректный формат подписанного манифеста.');
    }
    final raw = base64Decode(envelope['payload'] as String);
    final sig = base64Decode(envelope['signature'] as String);
    final pub = base64Decode(publicKeyBase64);
    if (raw.length > 8192 || sig.length != 64 || pub.length != 32) {
      throw const FormatException('Некорректный размер подписи обновления.');
    }
    final verified = await Ed25519().verify(
      raw,
      signature: Signature(sig,
          publicKey: SimplePublicKey(pub, type: KeyPairType.ed25519)),
    );
    if (!verified) throw const FormatException('Подпись релиза недействительна.');
    final data = jsonDecode(utf8.decode(raw));
    if (data is! Map<String, dynamic>) {
      throw const FormatException('Неверное содержимое манифеста.');
    }
    final version = data['version'];
    final download = Uri.tryParse('${data['download_url'] ?? ''}');
    final sha = data['sha256'];
    // A payload ZIP contains files only. No downloaded program is ever directly
    // executed. All ZIP entry paths are checked again by the detached updater.
    if (version is! String || !RegExp(r'^\d+\.\d+\.\d+$').hasMatch(version) ||
        download == null || download.scheme != 'https' || download.userInfo.isNotEmpty ||
        download.hasFragment || !download.path.toLowerCase().endsWith('.zip') ||
        download.host.toLowerCase() != 'github.com' ||
        sha is! String || !RegExp(r'^[a-f0-9]{64}$').hasMatch(sha)) {
      throw const FormatException('Небезопасные метаданные обновления.');
    }
    if (!newer(version, currentVersion)) return null;
    return UpdateInfo(version, download, sha, notes: '${data['notes'] ?? ''}');
  }

  static Future<String> sha256File(File file) async =>
      (await crypto.sha256.bind(file.openRead()).first).toString();

  /// The archive is downloaded as a stream, bounded in size, and verified
  /// *before* an updater process is launched.
  Future<File> downloadVerified(UpdateInfo info, {void Function(double progress)? onProgress}) async {
    final dir = await getTemporaryDirectory();
    final target = File('${dir.path}${Platform.pathSeparator}circle-update-${info.version}.zip');
    final partial = File('${target.path}.part');
    try {
      var current = info.download;
      http.StreamedResponse? response;
      for (var hop = 0; hop < 8; hop++) {
        final request = http.Request('GET', current)..followRedirects = false;
        final next = await _client.send(request).timeout(const Duration(seconds: 25));
        if (next.statusCode == 200) {
          response = next;
          break;
        }
        if (![301, 302, 303, 307, 308].contains(next.statusCode)) {
          throw StateError('Ошибка загрузки: HTTP ${next.statusCode}');
        }
        final location = next.headers['location'];
        if (location == null) throw const FormatException('Нет адреса перенаправления.');
        final destination = current.resolve(location);
        if (destination.scheme != 'https' || destination.userInfo.isNotEmpty ||
            destination.hasFragment) {
          throw const FormatException('Небезопасное перенаправление скачивания.');
        }
        current = destination;
        await next.stream.drain<void>();
      }
      if (response == null) throw const FormatException('Слишком много перенаправлений.');
      final sink = partial.openWrite();
      var total = 0;
      final declaredSize = response.contentLength ?? -1;
      try {
        await for (final chunk in response.stream.timeout(const Duration(seconds: 45))) {
          total += chunk.length;
          if (total > 800 * 1024 * 1024) {
            throw const FormatException('Пакет больше 800 МиБ.');
          }
          sink.add(chunk);
          if (declaredSize > 0) onProgress?.call((total / declaredSize).clamp(0.0, 1.0));
        }
      } finally {
        await sink.close();
      }
      final digest = await sha256File(partial);
      if (digest != info.sha256) throw const FormatException('SHA-256 пакета не совпадает.');
      if (await target.exists()) await target.delete();
      return await partial.rename(target.path);
    } catch (_) {
      if (await partial.exists()) await partial.delete();
      rethrow;
    }
  }

  /// Copies the trusted updater out of the application folder before starting
  /// it. It can therefore move/replace the whole folder, including itself.
  static Future<void> installAndRestart(UpdateInfo release, File verifiedZip) async {
    if (!Platform.isWindows) throw const FormatException('Обновления доступны только на Windows.');
    final exe = File(Platform.resolvedExecutable);
    final appDir = exe.parent;
    final updaterSource = File('${appDir.path}${Platform.pathSeparator}tools${Platform.pathSeparator}apply_update.ps1');
    if (!await updaterSource.exists()) {
      throw StateError('Не найден компонент установки обновлений.');
    }
    final support = Directory('${(await getApplicationSupportDirectory()).path}${Platform.pathSeparator}updates');
    await support.create(recursive: true);
    final script = File('${support.path}${Platform.pathSeparator}apply_update.ps1');
    await updaterSource.copy(script.path);
    final process = await Process.start('powershell.exe', [
      '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
      '-WindowStyle', 'Hidden', '-File', script.path,
      '-Archive', verifiedZip.path,
      '-ExpectedSha256', release.sha256,
      '-ExePath', exe.path,
      '-ParentPid', '$pid',
      '-Version', release.version,
    ], workingDirectory: support.path, mode: ProcessStartMode.detached);
    if (process.pid <= 0) throw StateError('Не удалось запустить компонент обновления.');
    // Separate process waits for this process to exit; then swaps binaries and
    // launches the new version. No Inno Setup UI or admin rights are required.
    exit(0);
  }
}
