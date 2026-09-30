// scratch stub of client/lib/config.dart (the real one needs shared_preferences -> Flutter)
class ApiConfig {
  static String get apiKey => 'x';
  static String get sessionId => 's';
  static String get baseUrl => 'http://127.0.0.1:8000';
  static const Duration requestTimeout = Duration(seconds: 15);
}
