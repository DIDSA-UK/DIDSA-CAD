import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for backend connection details, per the project
/// brief's instruction not to scatter the base URL/key through the codebase.
///
/// Stage 18 moves these from compile-time `lib/secrets.dart` constants to a
/// runtime [ConnectionScreen]-driven flow backed by `shared_preferences` -
/// [load] populates the in-memory cache the getters below read from (called
/// once at app startup, before any screen that talks to the backend), and
/// [save] persists+applies new values once a health check against them
/// succeeds.
class ApiConfig {
  ApiConfig._();

  static const String serverUrlPrefKey = 'server_url';
  static const String apiKeyPrefKey = 'api_key';

  static String _baseUrl = '';
  static String _apiKey = '';
  static String? _sessionId;

  /// The backend base URL, e.g. `https://cad-api.snail-shell.uk` - empty
  /// until [load] or [save] has run at least once.
  static String get baseUrl => _baseUrl;

  /// Sent as the `X-API-Key` header on every request - empty until [load]
  /// or [save] has run at least once.
  static String get apiKey => _apiKey;

  /// Whether both [baseUrl] and [apiKey] are non-empty - drives whether
  /// [ConnectionScreen] can pre-fill its fields and offer Connect on cold
  /// launch.
  static bool get isConfigured => _baseUrl.isNotEmpty && _apiKey.isNotEmpty;

  /// Sent as the `X-Document-Session` header on every `DocumentApiClient`/
  /// `SketchApiClient` request - identifies this app process's own
  /// document-editing session to the backend, so a second tab/device/app
  /// instance pointed at the same [baseUrl] (the backend has no isolation
  /// of its own beyond this header - see the backend's own
  /// `app.session_context` docstring) never shares or silently overwrites
  /// this session's in-memory Document/Sketch state. That cross-session
  /// clobbering - not this app's own Save-reuses-the-last-path behaviour -
  /// was the actual cause of a Save writing out a different, unrelated
  /// model.
  ///
  /// Generated once per process, lazily on first use, and cached for the
  /// rest of the process's lifetime - deliberately NOT reset by [load] or
  /// [save], so revisiting Connection Settings mid-session (which re-runs
  /// [load]) never orphans in-progress unsaved backend state under a freshly
  /// generated id.
  static String get sessionId => _sessionId ??= _generateSessionId();

  static String _generateSessionId() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  }

  /// Populates the in-memory cache from `shared_preferences` - a no-op
  /// (leaves both empty) on first-ever launch, before any value has been
  /// [save]d.
  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _baseUrl = prefs.getString(serverUrlPrefKey) ?? '';
    _apiKey = prefs.getString(apiKeyPrefKey) ?? '';
  }

  /// Persists [baseUrl]/[apiKey] to `shared_preferences` and updates the
  /// in-memory cache every subsequent request reads from - called by
  /// [ConnectionScreen] only after its own health check against them
  /// succeeds, never speculatively.
  static Future<void> save({required String baseUrl, required String apiKey}) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(serverUrlPrefKey, baseUrl);
    await prefs.setString(apiKeyPrefKey, apiKey);
    _baseUrl = baseUrl;
    _apiKey = apiKey;
  }

  /// The backend is a Raspberry Pi over a home internet connection and
  /// Cloudflare Tunnel, not localhost - allow real headroom for latency
  /// before treating a request as failed.
  static const Duration requestTimeout = Duration(seconds: 15);
}
