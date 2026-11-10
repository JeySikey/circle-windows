import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/startup_log.dart';

void main() {
  test('Logging does not throw even without Windows LOCALAPPDATA', () {
    expect(() => CircleStartupLog.write('Circle startup test'), returnsNormally);
    expect(() => CircleStartupLog.report('startup', StateError('test'), StackTrace.empty), returnsNormally);
  });
}
