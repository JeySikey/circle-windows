import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/updater.dart';
void main() {
  test('version ordering', () {
    expect(CircleUpdater.newer('0.3.1','0.3.0'),isTrue);
    expect(CircleUpdater.newer('0.3.0','0.3.0'),isFalse);
    expect(CircleUpdater.newer('0.2.9','0.3.0'),isFalse);
    expect(CircleUpdater.newer('invalid','0.3.0'),isFalse);
  });
}
