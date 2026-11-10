import 'dart:io';

/// Minimal diagnostic log for errors before login. Never logs API headers,
/// passwords, bearer tokens or user content. Log files stay local on Windows.
class CircleStartupLog {
  static final File? _file = _logFile();
  static File? _logFile() {
    try {
      final root = Platform.environment['LOCALAPPDATA'];
      if (root == null || root.isEmpty) return null;
      final directory = Directory('$root\\Circle\\logs');
      directory.createSync(recursive: true);
      return File('${directory.path}\\startup.log');
    } catch (_) {
      return null;
    }
  }

  static String? get path => _file?.path;

  static void write(String message) {
    try {
      _file?.writeAsStringSync(
        '[${DateTime.now().toIso8601String()}] $message\n',
        mode: FileMode.append, flush: true,
      );
    } catch (_) {
      // Logging must never interfere with application startup.
    }
  }

  static void report(String step, Object error, StackTrace? stack) {
    // Exception classes and stack locations are sufficient for first triage.
    // Do not include the exception.toString(): HTTP errors can contain data.
    write('$step: ${error.runtimeType}');
    if (stack != null) {
      final locations = stack.toString().split('\n').take(5).join(' | ');
      write('stack: $locations');
    }
  }
}
