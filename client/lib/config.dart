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
  static const String localApiKeyPrefKey = 'local_api_key';

  static String _baseUrl = '';
  static String _apiKey = '';
  static String _localApiKey = '';
  static String? _sessionId;

  /// The backend base URL, e.g. `https://cad-api.snail-shell.uk` - empty
  /// until [load] or [save] has run at least once.
  static String get baseUrl => _baseUrl;

  /// Sent as the `X-API-Key` header on every request - empty until [load]
  /// or [save] has run at least once.
  static String get apiKey => _apiKey;

  /// The API key most recently used to start the on-device standalone
  /// backend (see [saveLocalApiKey]/`server_management/termux_controller
  /// .dart`'s `startServer`/`restartServer`) - deliberately tracked
  /// separately from [apiKey] rather than reusing it directly, since
  /// [apiKey] reflects whichever server the client is *currently* pointed
  /// at (which may since have changed to a different, remote server) and
  /// would otherwise go stale as a record of what the local server was
  /// actually last told to use. Empty until a local start/restart has
  /// happened at least once, on this device, since install.
  static String get localApiKey => _localApiKey;

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
    _localApiKey = prefs.getString(localApiKeyPrefKey) ?? '';
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

  /// Stamps [key] as [localApiKey] - called by `TermuxController`'s own
  /// `startServer`/`restartServer` with whatever key it just exported as
  /// CAD_API_KEY inside Termux, so this always reflects what the local
  /// server actually has, independent of [save]'s own [apiKey] (which may
  /// point at a different server entirely by the time anything reads this
  /// back). Unlike [save], not gated on a health check succeeding first -
  /// the dispatched command may still fail for reasons this method can't
  /// see, so this records what was *attempted*, not a confirmed-working
  /// value; [ConnectionScreen]'s own health check on Connect is still what
  /// actually verifies it.
  static Future<void> saveLocalApiKey(String key) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(localApiKeyPrefKey, key);
    _localApiKey = key;
  }

  /// Returns [localApiKey], generating and persisting a fresh random one
  /// first if it's still empty (first local start ever, on this device).
  /// This is what actually breaks a circular dependency that otherwise
  /// stops the local server from ever starting the *first* time: the
  /// backend refuses to start without a non-empty CAD_API_KEY (see
  /// app/auth.py), but [apiKey] only ever gets set by [save], which
  /// [ConnectionScreen] only calls after a *successful* health check
  /// against a server already running with that exact key - a server that,
  /// on first install, doesn't exist yet because nothing has started it.
  /// Using [apiKey] (or requiring the user type one in Connection Settings
  /// first) as the local server's own key would leave that loop with no
  /// way in. Generating [localApiKey] independently, right here, is what
  /// lets `TermuxController.startServer`/`pullAndStart`/`restartServer`
  /// bootstrap a working server with no pre-existing key at all - the
  /// Connection screen's own "Use Local Server" button then reads this
  /// same value back afterward.
  static Future<String> ensureLocalApiKey() async {
    if (_localApiKey.isNotEmpty) return _localApiKey;
    final random = Random.secure();
    final bytes = List<int>.generate(32, (_) => random.nextInt(256));
    final key = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    await saveLocalApiKey(key);
    return key;
  }

  /// The backend is a Raspberry Pi over a home internet connection and
  /// Cloudflare Tunnel, not localhost - allow real headroom for latency
  /// before treating a request as failed.
  static const Duration requestTimeout = Duration(seconds: 15);

  /// [DocumentApiClient]'s own default timeout, used for every `/document`
  /// call rather than [requestTimeout] - almost any of them (every Feature
  /// create/update, `GET /mesh`, native import/export, STEP/STL/glb export)
  /// can trigger a full-Part OCCT recompute server-side (`compute_part_
  /// bodies` replays the whole Feature history from scratch, uncached), and
  /// a complex helical/herringbone `GearFeature` - or worse, a `BevelGear`/
  /// `BevelPairFeature` (Tredgold-built flanks sewn into a solid, doubled
  /// for a pair's two members - the single most expensive build in
  /// this codebase) - alone can take well past [requestTimeout] on the Pi 5
  /// target hardware - see `docs/gear-design/` for the shape of that cost.
  /// [SketchApiClient]'s own calls (2D constraint solving via py-slvs) stay
  /// on the short [requestTimeout] - they've never been reported slow, and
  /// a genuinely unreachable server should still fail fast for those.
  /// Deliberately blanket across every `/document` endpoint rather than
  /// triaged call-by-call: which Parts are expensive is data-dependent (any
  /// call that touches a Part containing a slow Feature inherits its cost,
  /// not just the call that first created it), so a per-endpoint split
  /// would just be a slower-to-maintain, easier-to-get-wrong version of the
  /// same blanket allowance - raised from 90s to 180s (on-device feedback,
  /// bevel timeout investigation) for headroom on a complex Bevel Pair,
  /// alongside the `points_per_flank` control on both gear screens that
  /// lets a user dial the cost down directly.
  static const Duration documentRequestTimeout = Duration(seconds: 180);

  /// `docs/gear-design/13-spiral-bevel-pair.md`'s own real cost decision:
  /// a spiral `BevelPairFeature` create/update runs a real per-build
  /// meshing-phase search (`12-spiral-bevel-gear.md`'s own Spike C) on top
  /// of both members' own already-expensive build - that spike's own
  /// on-device numbers put a single search trial at 1-3s in the
  /// well-behaved regime but up to ~16s near/past a notch, times this
  /// app's own bounded ~33-trial eval budget (`app.document.bevel_pair`'s
  /// own `_PHASE_SEARCH_GRID_POINTS`/`_PHASE_SEARCH_REFINE_ITERATIONS`) -
  /// up to roughly 9 minutes for the search alone in the worst case, on
  /// top of both members' own build cost (which itself grows near a notch).
  /// [documentRequestTimeout]'s own 180s (already raised once for a plain,
  /// non-spiral Bevel Pair) is nowhere near enough headroom for this - a
  /// SECOND, dedicated raise, used only for a spiral Bevel Pair's own
  /// create/update call (`DocumentApiClient.createBevelPairFeature`/
  /// `updateBevelPairFeature`, gated on `spiralAngleDegrees != 0.0`) rather
  /// than raising every `/document` call's own timeout for a cost that's
  /// concentrated in exactly one Feature type's own worst case.
  static const Duration spiralBevelPairRequestTimeout = Duration(seconds: 720);
}
