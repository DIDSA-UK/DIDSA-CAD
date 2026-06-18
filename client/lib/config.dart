import 'secrets.dart' as secrets;

/// Single source of truth for backend connection details, per the project
/// brief's instruction not to scatter the base URL/key through the codebase.
class ApiConfig {
  ApiConfig._();

  /// The deployed backend (Raspberry Pi 5, behind a Cloudflare Tunnel).
  /// See docs/project-brief.md Section 2.
  static const String _productionBaseUrl = 'https://cad-api.snail-shell.uk';

  /// Override via `apiBaseUrlOverride` in the gitignored lib/secrets.dart,
  /// e.g. to point at a local backend during development.
  static String get baseUrl => secrets.apiBaseUrlOverride ?? _productionBaseUrl;

  /// Sent as the `X-API-Key` header on every request. The real value lives
  /// only in the gitignored lib/secrets.dart - never hardcode it here.
  static String get apiKey => secrets.apiKey;

  /// The backend is a Raspberry Pi over a home internet connection and
  /// Cloudflare Tunnel, not localhost - allow real headroom for latency
  /// before treating a request as failed.
  static const Duration requestTimeout = Duration(seconds: 15);
}
