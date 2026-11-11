import 'dart:convert';
import 'dart:io';

import 'package:crypto/crypto.dart' as crypto;
import 'package:cryptography/cryptography.dart';
import 'package:path_provider/path_provider.dart';
import 'package:http/http.dart' as http;

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

  /// Windows updater and the PowerShell worker must use exactly the same folder.
  static String windowsUpdatesPath(String localAppData) {
    if (localAppData.trim().isEmpty) {
      throw StateError('Windows не передала путь LOCALAPPDATA.');
    }
    final trimmed = localAppData.replaceAll(RegExp(r'[\\/]+$'), '');
    return '$trimmed\\Circle\\updates';
  }

  static String updateDiagnosticsPath() => windowsUpdatesPath(
        Platform.environment['LOCALAPPDATA'] ?? '',
      );

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

  /// Keep the app open until PowerShell has verified and staged the payload.
  /// A normally-started child keeps running after exit(0), while its stderr
  /// and exitCode are available before the handshake. The launch record is
  /// created BEFORE spawning PowerShell, so even parser/start failures are
  /// actionable instead of a silent 120-second timeout.
  static Future<void> installAndRestart(UpdateInfo release, File verifiedZip) async {
    if (!Platform.isWindows) {
      throw const FormatException('Обновления доступны только на Windows.');
    }
    final exe = File(Platform.resolvedExecutable);
    final appDir = exe.parent;
    final updaterSource = File(
      '${appDir.path}${Platform.pathSeparator}tools${Platform.pathSeparator}apply_update.ps1',
    );
    if (!await updaterSource.exists()) {
      throw StateError('В установленной версии отсутствует tools\\apply_update.ps1. '
          'Потребуется однократная установка исправленного Circle.');
    }

    final support = Directory(updateDiagnosticsPath());
    await support.create(recursive: true);
    final launcherLog = File('${support.path}${Platform.pathSeparator}launcher.log');
    Future<void> log(String message) async {
      await launcherLog.writeAsString(
        '${DateTime.now().toIso8601String()} $message\n',
        mode: FileMode.append,
        flush: true,
      );
    }

    final nonce = DateTime.now().microsecondsSinceEpoch;
    final script = File('${support.path}${Platform.pathSeparator}apply_update_$nonce.ps1');
    final handshake = File('${support.path}${Platform.pathSeparator}ready_$nonce.txt');
    await updaterSource.copy(script.path);
    await log('Preparing Circle ${release.version}; script copied; EXE present: ${await exe.exists()}; '
        'ZIP present: ${await verifiedZip.exists()}');

    final windowsRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
    final powershell = '$windowsRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe';
    Process process;
    try {
      // Normal mode exposes the actual exit code. Dart documents that the
      // child continues running if its parent explicitly calls exit(0).
      process = await Process.start(
        powershell,
        [
          '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass',
          '-WindowStyle', 'Hidden', '-File', script.path,
          '-Archive', verifiedZip.path,
          '-ExpectedSha256', release.sha256,
          '-ExePath', exe.path,
          '-ParentPid', '$pid',
          '-Version', release.version,
          '-HandshakeFile', handshake.path,
        ],
        workingDirectory: support.path,
        mode: ProcessStartMode.normal,
      );
    } on ProcessException catch (error) {
      await log('FAILED starting PowerShell: $error');
      throw StateError('Не удалось запустить PowerShell: $error. '
          'Диагностика: ${launcherLog.path}');
    }

    await log('PowerShell started, PID ${process.pid}; waiting for ready handshake');
    // Consume streams to avoid blocked pipes. Keep only a bounded excerpt;
    // the detailed PowerShell log is kept separately as update.log.
    final output = StringBuffer();
    void remember(String chunk) {
      if (output.length < 6000) {
        final remaining = 6000 - output.length;
        output.write(chunk.length <= remaining ? chunk : chunk.substring(0, remaining));
      }
    }
    final stdoutFinished = process.stdout.transform(const Utf8Decoder(allowMalformed: true))
        .listen(remember).asFuture<void>();
    final stderrFinished = process.stderr.transform(const Utf8Decoder(allowMalformed: true))
        .listen(remember).asFuture<void>();
    await process.stdin.close();
    int? exitCode;
    // There is no polling of stdout and no assumption that a started process
    // necessarily entered the PowerShell script.
    process.exitCode.then((value) { exitCode = value; });

    var ready = false;
    for (var attempt = 0; attempt < 480; attempt++) {
      if (await handshake.exists()) {
        ready = (await handshake.readAsString()).trim() == 'ready';
        if (ready) break;
      }
      if (exitCode != null) break;
      await Future<void>.delayed(const Duration(milliseconds: 250));
    }

    if (!ready) {
      if (exitCode != null) {
        try {
          await Future.wait([stdoutFinished, stderrFinished])
              .timeout(const Duration(seconds: 2));
        } on Exception {
          // Keep any already captured output.
        }
      }
      final detail = output.toString().trim();
      await log('FAILED before handshake; processExit=${exitCode ?? "still running"}; '
          'output=${detail.isEmpty ? "(empty)" : detail}');
      throw StateError('Обновлятор не подготовил установку '
          '(PowerShell: ${exitCode == null ? "нет подтверждения" : "код $exitCode"}). '
          '${detail.isEmpty ? "" : "Ошибка: ${detail.length > 420 ? detail.substring(0, 420) : detail}. "}'
          'Подробности: ${launcherLog.path}');
    }
    await log('Payload staged. Handshake received. Closing Circle for atomic replacement.');
    try {
      await handshake.delete();
    } on FileSystemException {
      // The external updater may still have its handshake open momentarily.
    }
    // PowerShell waits until this exact process terminates, swaps full runtime
    // files, restores Inno uninstall metadata, and restarts the new Circle.
    exit(0);
  }

}
