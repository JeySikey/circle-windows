import 'package:flutter_test/flutter_test.dart';
import 'package:circle_windows/api.dart';

void main() {
  test('Requires HTTPS root without embedded credentials', () {
    expect(() => CircleApi('http://example.com'), throwsA(isA<CircleError>()));
    expect(() => CircleApi('https://user:pass@example.com'), throwsA(isA<CircleError>()));
    expect(() => CircleApi('https://example.com/other'), throwsA(isA<CircleError>()));
    expect(() => CircleApi('https://example.com?q=token'), throwsA(isA<CircleError>()));
    final api = CircleApi('https://example.com');
    expect(api.uri('feed').toString(), 'https://example.com/api/mobile.php?route=feed');
    api.dispose();
  });
  test('Safe parsing of API records', () {
    expect(items({'items': [{'id': 1}, {'id': 2}]}).length, 2);
    expect(items({}), isEmpty);
    expect(identifier('42'), 42);
    expect(identifier('invalid'), 0);
  });
}
