import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'termux_commands.dart';

/// Whether a dispatched command's result is currently unknown, or has been
/// confirmed via a real /health round trip - see [TermuxController.check].
enum ServerReachability { unknown, reachable, unreachable }

/// A single /health round trip's full result - see [TermuxController
/// .checkStatus]. [branch] is only ever non-null when [reachability] is
/// [ServerReachability.reachable] with a response body that actually
/// included it - the backend reports its own git branch (see
/// app/main.py's own `git_branch` field), so this reflects what's really
/// running, not a value guessed or remembered client-side.
class ServerStatus {
  const ServerStatus({required this.reachability, this.branch});

  final ServerReachability reachability;
  final String? branch;
}

/// Thin wrapper over the `uk.snail_shell.didsa_cad_client/termux`
/// MethodChannel (see android/.../MainActivity.kt) plus a real /health poll
/// - the platform channel only confirms Android handed an intent to
/// Termux, never that the command inside it actually succeeded (Termux
/// might not be installed, the proot-distro environment might be missing,
/// the server might crash on startup, etc.), so every action here is
/// followed by asking the backend itself whether it's actually there.
class TermuxController {
  TermuxController({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  static const MethodChannel _channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');

  /// Fixed, not [ApiConfig.baseUrl] - this screen only ever controls a
  /// backend on *this* device, on the fixed port termux_commands.dart
  /// starts it on, regardless of where [ApiConfig] happens to be pointed
  /// right now. If Connection Settings currently points somewhere else
  /// (e.g. the Pi over Cloudflare Tunnel), health-checking that address
  /// instead would silently tell the user nothing true about what this
  /// screen's own Start/Stop/Restart buttons actually did.
  static const String localBaseUrl = 'http://127.0.0.1:8000';

  final http.Client _httpClient;

  Future<bool> hasPermission() async {
    final result = await _channel.invokeMethod<bool>('hasPermission');
    return result ?? false;
  }

  Future<bool> requestPermission() async {
    final result = await _channel.invokeMethod<bool>('requestPermission');
    return result ?? false;
  }

  /// The raw dump TermuxResultService last captured from whatever Termux
  /// actually sent back via the RUN_COMMAND_PENDING_INTENT result callback
  /// - see that class's own doc comment for why this is unparsed text
  /// rather than a typed result (the exact Termux result-bundle schema
  /// wasn't confirmed against primary source, so the native side captures
  /// everything present rather than betting on assumed key names). Always
  /// returns *something* displayable, never null/throws - a placeholder
  /// string if nothing has arrived yet.
  Future<String> getLastCommandResult() async {
    final result = await _channel.invokeMethod<String>('getLastCommandResult');
    return result ?? '(no result available)';
  }

  /// Returns false only if the intent itself couldn't be dispatched
  /// (missing permission, Termux not installed) - see MainActivity.kt's
  /// own doc comment on what this return value does and doesn't confirm.
  Future<bool> _dispatch(List<String> arguments) async {
    final result = await _channel.invokeMethod<bool>('runCommand', {
      'executable': TermuxCommands.executable,
      'arguments': arguments,
    });
    return result ?? false;
  }

  Future<bool> pullLatest(String branch) => _dispatch(TermuxCommands.pullLatest(branch));

  /// Pull [branch] then start, as one dispatched command - see
  /// [TermuxCommands.pullAndStart]'s own doc comment for why this can't be
  /// two separate calls to [pullLatest] and [startServer] (a real race:
  /// RUN_COMMAND_BACKGROUND returns before the command it dispatched has
  /// actually finished). The single most useful action for "test this
  /// branch" - fetches it fresh and boots it in one tap, rather than the
  /// user having to Pull, wait, then separately remember to Start.
  Future<bool> pullAndStart(String branch) async {
    final key = await ApiConfig.ensureLocalApiKey();
    return _dispatch(TermuxCommands.pullAndStart(branch, key));
  }

  /// Uses [ApiConfig.ensureLocalApiKey] - not [ApiConfig.apiKey] - as the
  /// key exported as CAD_API_KEY, so a local start never depends on a
  /// remote-server key that may not exist yet (see that method's own doc
  /// comment for why using [ApiConfig.apiKey] here would be circular:
  /// it's only ever set *after* a successful connection to a server that,
  /// on first install, doesn't exist until something starts it).
  Future<bool> startServer() async {
    final key = await ApiConfig.ensureLocalApiKey();
    return _dispatch(TermuxCommands.startServer(key));
  }

  Future<bool> stopServer() => _dispatch(TermuxCommands.stopServer());

  Future<bool> restartServer() async {
    final key = await ApiConfig.ensureLocalApiKey();
    return _dispatch(TermuxCommands.restartServer(key));
  }

  /// A single GET /health round trip against [localBaseUrl] - always uses
  /// [ApiConfig.localApiKey], not [ApiConfig.apiKey]: /health requires the
  /// API key too (see app/main.py's own comment - deliberately, not an
  /// oversight), and the local server is started with [ApiConfig
  /// .localApiKey] (via [startServer]/[restartServer]/[pullAndStart]), not
  /// whatever [ApiConfig.apiKey] happens to currently hold - those two can
  /// easily differ (e.g. [ApiConfig.apiKey] pointing at a remote server,
  /// or still empty on a fresh install). Short timeout: this is a local,
  /// same-device call (unlike [ApiConfig.requestTimeout]'s own comment
  /// about allowing headroom for a real network round trip to the Pi), so
  /// a slow response is itself a meaningful "something's wrong" signal.
  /// [ServerStatus.branch] parsing failures (bad JSON, missing field) are
  /// swallowed to null rather than affecting [ServerStatus.reachability] -
  /// a 2xx /health response is still a genuinely reachable server even if
  /// its body doesn't parse the way this client expects.
  Future<ServerStatus> checkStatus() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('$localBaseUrl/health'), headers: {'X-API-Key': ApiConfig.localApiKey})
          .timeout(const Duration(seconds: 5));
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return const ServerStatus(reachability: ServerReachability.unreachable);
      }
      String? branch;
      try {
        branch = (jsonDecode(response.body) as Map<String, dynamic>)['git_branch'] as String?;
      } catch (_) {
        branch = null;
      }
      return ServerStatus(reachability: ServerReachability.reachable, branch: branch);
    } catch (_) {
      return const ServerStatus(reachability: ServerReachability.unreachable);
    }
  }

  Future<ServerReachability> check() async => (await checkStatus()).reachability;

  /// Polls [check] every [interval] until it reports [expect] or [timeout]
  /// elapses - a start/restart takes a real, variable amount of time
  /// (micromamba activation, then uvicorn importing pythonocc-core - a
  /// large compiled CAD kernel - all under proot's ptrace overhead), so a
  /// single immediate check right after dispatching the intent would
  /// almost always read "unreachable" even on a genuinely successful
  /// start. 60s (not a shorter default) because on-device testing showed a
  /// cold start alone can take longer than 20s to become reachable.
  Future<ServerReachability> pollUntil({
    required ServerReachability expect,
    Duration timeout = const Duration(seconds: 60),
    Duration interval = const Duration(seconds: 2),
  }) async {
    final deadline = DateTime.now().add(timeout);
    var last = await check();
    while (last != expect && DateTime.now().isBefore(deadline)) {
      await Future.delayed(interval);
      last = await check();
    }
    return last;
  }

  void dispose() => _httpClient.close();
}
