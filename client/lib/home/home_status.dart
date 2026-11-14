/// What the home screen's two status lights show: is the CAD server there, and is cloud storage online.
///
/// A light probe (`GET /health` on each, a few seconds' timeout) at launch, on return to the home screen and every half minute while it
/// is showing. Nothing here changes a setting or starts a sync; it only looks.
library;

import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:material_ui/material_ui.dart';

import '../config.dart';
import '../storage/server/store_client.dart';

/// Not set up (grey), reachable (green), set up but not answering (red); [checking] is the first look, shown as grey without greying
/// anything out.
enum ServerLight { notSetUp, checking, connected, unreachable }

/// A local folder only (grey), cloud storage answering (green), set up but not answering or refusing the key (red).
enum StorageLight { localOnly, checking, online, offline }

class HomeStatus {
  const HomeStatus({
    this.server = ServerLight.checking,
    this.storage = StorageLight.checking,
    this.serverDetail = '',
    this.storageDetail = '',
  });

  final ServerLight server;
  final StorageLight storage;

  /// A short line for the tile: the host name, "Not set up", "Can't reach the server".
  final String serverDetail;
  final String storageDetail;

  /// CAD tools and the VR headset need a server; while it is still being looked at they stay open.
  bool get serverUsable => server == ServerLight.connected || server == ServerLight.checking;

  @override
  bool operator ==(Object other) =>
      other is HomeStatus &&
      other.server == server &&
      other.storage == storage &&
      other.serverDetail == serverDetail &&
      other.storageDetail == storageDetail;

  @override
  int get hashCode => Object.hash(server, storage, serverDetail, storageDetail);
}

class HomeStatusController extends ChangeNotifier {
  HomeStatusController({http.Client? httpClient, this.interval = const Duration(seconds: 30), this.timeout = const Duration(seconds: 6)})
      : _http = httpClient;

  final http.Client? _http;
  final Duration interval;
  final Duration timeout;
  Timer? _timer;
  bool _disposed = false;

  HomeStatus _value = const HomeStatus();
  HomeStatus get value => _value;

  /// Looks now, then again every [interval] until [stop] or dispose.
  void start() {
    _timer?.cancel();
    unawaited(refresh());
    _timer = Timer.periodic(interval, (_) => unawaited(refresh()));
  }

  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  Future<void> refresh() async {
    final results = await Future.wait([_probeServer(), _probeStorage()]);
    if (_disposed) return;
    final next = HomeStatus(
      server: results[0].$1 as ServerLight,
      serverDetail: results[0].$2,
      storage: results[1].$1 as StorageLight,
      storageDetail: results[1].$2,
    );
    if (next != _value) {
      _value = next;
      notifyListeners();
    }
  }

  Future<(Object, String)> _probeServer() async {
    final url = ApiConfig.baseUrl;
    if (!ApiConfig.isConfigured) return (ServerLight.notSetUp, 'Not set up');
    final client = _http ?? http.Client();
    try {
      final response = await client.get(Uri.parse('$url/health'), headers: {'X-API-Key': ApiConfig.apiKey}).timeout(timeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return (ServerLight.connected, '${_host(url)} · connected');
      }
      return (ServerLight.unreachable, response.statusCode == 401 ? 'Server refused the key' : "Can't reach the server");
    } catch (_) {
      return (ServerLight.unreachable, "Can't reach the server");
    } finally {
      if (_http == null) client.close();
    }
  }

  Future<(Object, String)> _probeStorage() async {
    if (!ApiConfig.storeConfigured) return (StorageLight.localOnly, 'Local folder');
    final client = StoreClient(
      StoreSettings(url: ApiConfig.storeUrl, apiKey: ApiConfig.storeApiKey, deviceName: ApiConfig.effectiveDeviceName),
      httpClient: _http,
      timeout: timeout,
    );
    try {
      await client.health();
      return (StorageLight.online, 'Cloud storage · online');
    } on StoreAuthError {
      return (StorageLight.offline, 'Cloud storage refused the key');
    } catch (_) {
      return (StorageLight.offline, 'Cloud storage · offline');
    } finally {
      client.close();
    }
  }

  static String _host(String url) => Uri.tryParse(url)?.host.split('.').first.isNotEmpty == true ? Uri.parse(url).host : url;

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
