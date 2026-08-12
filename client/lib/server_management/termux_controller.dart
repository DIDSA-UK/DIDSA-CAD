import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../config.dart';
import 'termux_commands.dart';

/// Whether a dispatched command's result is currently unknown, or has been
/// confirmed via a real /health round trip - see [TermuxController.check].
enum ServerReachability { unknown, reachable, unreachable }

/// Thin wrapper over the `uk.snail_shell.didsa_cad_client/termux`
/// MethodChannel (see android/.../MainActivity.kt) plus a real /health poll
/// against [ApiConfig] - the platform channel only confirms Android handed
/// an intent to Termux, never that the command inside it actually
/// succeeded (Termux might not be installed, the proot-distro environment
/// might be missing, the server might crash on startup, etc.), so every
/// action here is followed by asking the backend itself whether it's
/// actually there, the same way ConnectionScreen already does.
class TermuxController {
  TermuxController({http.Client? httpClient}) : _httpClient = httpClient ?? http.Client();

  static const MethodChannel _channel = MethodChannel('uk.snail_shell.didsa_cad_client/termux');

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

  Future<bool> startServer() => _dispatch(TermuxCommands.startServer(ApiConfig.apiKey));

  Future<bool> stopServer() => _dispatch(TermuxCommands.stopServer());

  Future<bool> restartServer() => _dispatch(TermuxCommands.restartServer(ApiConfig.apiKey));

  /// A single GET /health round trip - reuses [ApiConfig]'s already-stored
  /// base URL/key (the same value that just got exported as CAD_API_KEY, if
  /// this followed a start/restart) rather than this screen tracking its
  /// own separate connection details. Short timeout: this is a local,
  /// same-device call (unlike [ApiConfig.requestTimeout]'s own comment
  /// about allowing headroom for a real network round trip to the Pi), so a
  /// slow response is itself a meaningful "something's wrong" signal.
  Future<ServerReachability> check() async {
    if (!ApiConfig.isConfigured) return ServerReachability.unreachable;
    try {
      final response = await _httpClient
          .get(Uri.parse('${ApiConfig.baseUrl}/health'), headers: {'X-API-Key': ApiConfig.apiKey})
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
