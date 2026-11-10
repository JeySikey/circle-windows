import 'dart:convert';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:circle_windows/updater.dart';

void main() {
  test('Derives GitHub release URL only from safe owner/repo', () {
    expect(CircleUpdater.githubManifestUri('circle-org/circle-windows').toString(),
        'https://github.com/circle-org/circle-windows/releases/latest/download/update-manifest.json');
    expect(CircleUpdater.githubManifestUri('../bad'), isNull);
    expect(CircleUpdater.githubManifestUri('owner/repo/path'), isNull);
    expect(CircleUpdater.githubManifestUri('owner/repo?token=x'), isNull);
  });

  test('Authenticates release manifest and rejects modified payload', () async {
    final algorithm = Ed25519();
    final pair = await algorithm.newKeyPair();
    final key = await pair.extractPublicKey();
    final payload = utf8.encode(jsonEncode({
      'version': '0.5.1',
      'download_url': 'https://github.com/circle-org/circle-windows/releases/download/v0.5.1/Circle_Windows_0.5.1_Payload.zip',
      'sha256': List.filled(64, 'a').join(),
    }));
    final signature = await algorithm.sign(payload, keyPair: pair);
    var damaged = false;
    final client = MockClient((_) async => http.Response(jsonEncode({
      'payload': base64Encode(damaged ? [...payload, 32] : payload),
      'signature': base64Encode(signature.bytes),
    }), 200));
    final updater = CircleUpdater(
      manifestUrl: Uri.parse('https://github.com/circle-org/circle-windows/releases/latest/download/update-manifest.json'),
      publicKeyBase64: base64Encode(key.bytes), client: client,
    );
    final release = await updater.check('0.5.0');
    expect(release?.version, '0.5.1');
    expect(release?.download.path.endsWith('_Payload.zip'), isTrue);
    damaged = true;
    await expectLater(updater.check('0.5.0'), throwsFormatException);
    updater.close();
  });
}
