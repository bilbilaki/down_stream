/// Simple logging abstraction for DownStream
class Logger {
  static bool _enabled = true;
  
  /// Enable or disable logging
  static void setEnabled(bool enabled) {
    _enabled = enabled;
  }
  
  /// Log an info message
  static void info(String message) {
    if (_enabled) {
      // ignore: avoid_print
      print('[DownStream] $message');
    }
  }
  
  /// Log an error message
  static void error(String message) {
    if (_enabled) {
      // ignore: avoid_print
      print('[DownStream ERROR] $message');
    }
  }
  
  /// Log a success message
  static void success(String message) {
    if (_enabled) {
      // ignore: avoid_print
      print('[DownStream ✅] $message');
    }
  }
  
  /// Log a cancel message
  static void cancel(String message) {
    if (_enabled) {
      // ignore: avoid_print
      print('[DownStream ❌] $message');
    }
  }
}
