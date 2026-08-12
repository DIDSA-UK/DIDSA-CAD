import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'termux_commands.dart';

/// Whether a dispatched command's result is currently unknown, or has been
/// confirmed via a real /health round trip - see [TermuxController.check].
enum ServerReachability { unknown, reachable, unreachable }

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
    await ApiConfig.saveLocalApiKey(ApiConfig.apiKey);
    return _dispatch(TermuxCommands.pullAndStart(branch, ApiConfig.apiKey));
  }

  /// Stamps [ApiConfig.localApiKey] with whatever key is exported, before
  /// dispatching - so the Connection screen's "Use Local Server" button
  /// always reflects what this call actually attempted, even if the
  /// intent dispatch itself then fails (matches [ApiConfig.saveLocalApiKey]
  /// 's own doc comment: this records an attempt, not a confirmed result).
  Future<bool> startServer() async {
    await ApiConfig.saveLocalApiKey(ApiConfig.apiKey);
    return _dispatch(TermuxCommands.startServer(ApiConfig.apiKey));
  }

  Future<bool> stopServer() => _dispatch(TermuxCommands.stopServer());

  Future<bool> restartServer() async {
    await ApiConfig.saveLocalApiKey(ApiConfig.apiKey);
    return _dispatch(TermuxCommands.restartServer(ApiConfig.apiKey));
  }

  /// A single GET /health round trip against [localBaseUrl] - always uses
  /// [ApiConfig.apiKey] as the X-API-Key (the same value startServer/
  /// restartServer exported as CAD_API_KEY, so this checks with whatever
  /// key the local server actually has, even an empty one - there's no
  /// meaningful auth boundary to protect against on a loopback-only,
  /// same-device call, so an empty key is a "you won't be able to Connect
  /// to this yet" usability note for the caller to surface, not something
  /// this method itself needs to guard against). Short timeout: this is a
  /// local, same-device call (unlike [ApiConfig.requestTimeout]'s own
  /// comment about allowing headroom for a real network round trip to the
  /// Pi), so a slow response is itself a meaningful "something's wrong"
  /// signal.
  Future<ServerReachability> check() async {
    try {
      final response = await _httpClient
          .get(Uri.parse('$localBaseUrl/health'), headers: {'X-API-Key': ApiConfig.apiKey})
          .timeout(const Duration(seconds: 5));
      return (response.statusCode >= 200 && response.statusCode < 300)
          ? ServerReachability.reachable
          : ServerReachability.unreachable;
    } catch (_) {
      return ServerReachability.unreachable;
    }
  }

  /// Polls [check] every [interval] until it reports [expect] or [timeout]
  /// elapses - a start/restart takes a real, variable amount of time
  /// (micromamba activation, uvicorn's own boot), so a single immediate
  /// check right after dispatching the intent would almost always read
  /// "unreachable" even on a genuinely successful start.
  Future<ServerReachability> pollUntil({
    required ServerReachability expect,
    Duration timeout = const Duration(seconds: 20),
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
