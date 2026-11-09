import 'dart:io';
import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/updater.dart';
void main() {
  test('sha256 file digest uses streaming hashing', () async {
    final dir = await Directory.systemTemp.createTemp('circle-windows-test-');
    try {
      final file = File('${dir.path}${Platform.pathSeparator}data.bin');
      await file.writeAsString('abc');
      expect(await CircleUpdater.sha256File(file),
          'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
    } finally {
      await dir.delete(recursive: true);
    }
  });

  test('version ordering', () {
    expect(CircleUpdater.newer('0.3.1','0.3.0'),isTrue);
    expect(CircleUpdater.newer('0.3.0','0.3.0'),isFalse);
    expect(CircleUpdater.newer('0.2.9','0.3.0'),isFalse);
    expect(CircleUpdater.newer('invalid','0.3.0'),isFalse);
  });
}
