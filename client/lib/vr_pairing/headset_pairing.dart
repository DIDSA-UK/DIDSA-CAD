import 'dart:convert';
import 'dart:io' show InternetAddressType, NetworkInterface;

import 'package:http/http.dart' as http;

import '../config.dart';

/// Connect a VR headset: the checks run before the pairing QR code is shown, and the code's contents.
///
/// The headset app (DIDSA-VR, `docs/landing-scope.md` "Adding a server") scans the code and stores the server, so nobody types
/// a URL or API key on a VR keyboard. The code is shown only once every check here passes: the server is set, it answers, the
/// headset could reach its address, and it has the endpoints the headset needs.
///
/// The on-phone server (Server Management, `http://127.0.0.1:8000`) pairs too: the code then carries the phone's Wi-Fi address,
/// once Server Management's "Let VR headsets on this Wi-Fi connect" has the server listening there.

/// How one check came out. [fail] stops the code being shown; [warn] shows it with a note.
enum PairingCheckState { pass, warn, fail }

class PairingCheck {
  final String title;
  final PairingCheckState state;
  final String message;

  const PairingCheck(this.title, this.state, this.message);

  bool get failed => state == PairingCheckState.fail;
}

/// What [HeadsetPairing.runChecks] found: every check, and (when nothing failed) the address and name the code carries. For the
/// on-phone server [pairUrl] is the phone's Wi-Fi address, not the `127.0.0.1` this app uses.
class PairingResult {
  final List<PairingCheck> checks;
  final String? pairUrl;
  final String name;

  const PairingResult(this.checks, {this.pairUrl, this.name = ''});

  bool get compatible => pairUrl != null && checks.every((c) => !c.failed);
}

class HeadsetPairing {
  HeadsetPairing._();

  /// The scheme the headset recognises. The number after the colon is the payload version: the headset refuses versions it does
  /// not know rather than guessing.
  static const String payloadScheme = 'didsa-vr';
  static const int payloadVersion = 1;

  /// Whether a plain `http://` address on the local network may be paired. Android's cleartext-HTTP rule is enforced by its Java
  /// networking stack; the headset app's requests go through Godot's own sockets, which it is not expected to cover (Android's
  /// `NetworkSecurityPolicy` docs say as much for the socket API). Not yet tried on a headset: if it turns out blocked there, set
  /// this false (and DIDSA-VR needs its network security config, landing scope step L0). Plain http on the internet stays refused.
  static const bool headsetAllowsLanHttp = true;

  /// What the headset app calls, by OpenAPI path. Without these it cannot open, show or save anything.
  static const List<String> requiredPaths = [
    '/health',
    '/document/import/native',
    '/document/export/native',
    '/document/parts/{part_id}/assembly-mesh.glb',
  ];

  /// Tools that need their own endpoints. A missing one is a warning: the headset still connects, that tool will not work.
  static const Map<String, String> optionalPaths = {
    '/document/parts/{part_id}/mates': 'Mates',
    '/document/parts/{part_id}/measure': 'Measure',
    '/document/parts/{part_id}/appearance-overrides': 'Appearance',
    '/document/parts/{part_id}/scenes': 'Scenes',
  };

  /// Whether the headset could reach [rawUrl] at all, judged from the address alone (nothing here can test the route from the
  /// headset itself).
  static PairingCheck checkAddress(String rawUrl) {
    const title = 'Address the headset can reach';
    final uri = Uri.tryParse(rawUrl.trim());
    if (uri == null || !uri.hasScheme || uri.host.isEmpty || (uri.scheme != 'http' && uri.scheme != 'https')) {
      return const PairingCheck(title, PairingCheckState.fail, 'The server URL is not a valid http(s) address.');
    }
    final host = uri.host.toLowerCase();
    if (_isLoopback(host)) {
      return const PairingCheck(
        title,
        PairingCheckState.fail,
        'This server runs on this device (localhost), so the headset cannot reach it. Use a server on another computer, '
        'or reach this one through an HTTPS tunnel.',
      );
    }
    if (host == '10.0.2.2') {
      return const PairingCheck(
        title,
        PairingCheckState.fail,
        '10.0.2.2 is the Android emulator\'s name for its own computer; a headset cannot use it.',
      );
    }
    if (host.startsWith('169.254.') || host.startsWith('fe80:')) {
      return const PairingCheck(
        title,
        PairingCheckState.fail,
        'This is a link-local address, which only works on one cable or adapter. Use the server\'s network address.',
      );
    }
    final local = _isLocalNetwork(host);
    if (uri.scheme == 'http') {
      if (!local) {
        return const PairingCheck(
          title,
          PairingCheckState.fail,
          'Android on the headset blocks plain http:// addresses on the internet. Use an https:// address.',
        );
      }
      if (!headsetAllowsLanHttp) {
        return const PairingCheck(
          title,
          PairingCheckState.fail,
          'The headset app accepts only https:// addresses for now (Android blocks plain http). Use an HTTPS address, for '
          'example a Cloudflare Tunnel; plain http on your own network comes with a later headset build.',
        );
      }
      return const PairingCheck(
        title,
        PairingCheckState.warn,
        'Plain http on your own network: the headset must be on the same Wi-Fi, and the API key travels unencrypted, so '
        'anything on this network could read it.',
      );
    }
    if (host.endsWith('.local')) {
      return const PairingCheck(
        title,
        PairingCheckState.warn,
        'A .local name may not resolve on the headset. If it cannot connect, use the server\'s IP address instead.',
      );
    }
    if (_isTailnet(host)) {
      return const PairingCheck(
        title,
        PairingCheckState.warn,
        'This is a Tailscale address: the headset must be on the same tailnet.',
      );
    }
    if (local && uri.scheme == 'https') {
      return const PairingCheck(
        title,
        PairingCheckState.warn,
        'A local https:// server needs a certificate the headset trusts; a self-signed one will be refused.',
      );
    }
    if (local) {
      return const PairingCheck(title, PairingCheckState.pass, 'On your local network: the headset must be on the same Wi-Fi.');
    }
    return const PairingCheck(title, PairingCheckState.pass, 'A public https:// address.');
  }

  /// The server answers `GET /health` with this key.
  static Future<PairingCheck> checkHealth(http.Client client, String baseUrl, String apiKey) async {
    const title = 'Server running';
    try {
      final response = await client
          .get(Uri.parse('${_trimmed(baseUrl)}/health'), headers: {'X-API-Key': apiKey})
          .timeout(ApiConfig.requestTimeout);
      if (response.statusCode == 401 || response.statusCode == 403) {
        return const PairingCheck(title, PairingCheckState.fail, 'The server refused the API key.');
      }
      if (response.statusCode < 200 || response.statusCode >= 300) {
        return PairingCheck(title, PairingCheckState.fail, 'The server answered ${response.statusCode}.');
      }
      return const PairingCheck(title, PairingCheckState.pass, 'The server answers.');
    } catch (_) {
      return const PairingCheck(title, PairingCheckState.fail, 'Could not reach the server. Is it running?');
    }
  }

  /// The server has the endpoints the headset calls (read from its `/openapi.json`, the schema FastAPI
  /// serves outside the API-key dependency; the key is sent anyway and is harmless there).
  static Future<PairingCheck> checkEndpoints(http.Client client, String baseUrl, String apiKey) async {
    const title = 'Server works with the headset';
    Map<String, dynamic>? paths;
    try {
      final response = await client
          .get(Uri.parse('${_trimmed(baseUrl)}/openapi.json'), headers: {'X-API-Key': apiKey})
          .timeout(ApiConfig.requestTimeout);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        final decoded = jsonDecode(response.body);
        if (decoded is Map<String, dynamic> && decoded['paths'] is Map<String, dynamic>) {
          paths = decoded['paths'] as Map<String, dynamic>;
        }
      }
    } catch (_) {
      paths = null;
    }
    if (paths == null) {
      return const PairingCheck(
        title,
        PairingCheckState.warn,
        'Could not read the server\'s API list, so this was not checked.',
      );
    }
    final missing = requiredPaths.where((p) => !paths!.containsKey(p)).toList();
    if (missing.isNotEmpty) {
      return PairingCheck(
        title,
        PairingCheckState.fail,
        'This server is too old for the headset (missing ${missing.join(', ')}). Update the backend.',
      );
    }
    final tools = [
      for (final entry in optionalPaths.entries)
        if (!paths.containsKey(entry.key)) entry.value,
    ];
    if (tools.isNotEmpty) {
      return PairingCheck(
        title,
        PairingCheckState.warn,
        'Connects, but this server has no ${tools.join(', ')}: ${tools.length == 1 ? 'that tool' : 'those tools'} will not work.',
      );
    }
    return const PairingCheck(title, PairingCheckState.pass, 'Has everything the headset uses.');
  }

  /// Every check in order. Stops after the first failure, since later checks would only repeat it.
  ///
  /// [localServerOnWifi] defaults to [ApiConfig.localServerOnWifi]; [wifiAddresses] to [phoneWifiAddresses] (both overridable for
  /// tests).
  static Future<PairingResult> runChecks({
    required http.Client client,
    required String baseUrl,
    required String apiKey,
    bool? localServerOnWifi,
    Future<List<String>> Function()? wifiAddresses,
  }) async {
    if (baseUrl.trim().isEmpty || apiKey.trim().isEmpty) {
      return const PairingResult([
        PairingCheck('Server set', PairingCheckState.fail, 'Connect this app to a server first, then try again.'),
      ]);
    }
    final checks = <PairingCheck>[
      const PairingCheck('Server set', PairingCheckState.pass, 'Using the server this app is connected to.'),
    ];
    var pairUrl = _trimmed(baseUrl);
    var name = defaultName(baseUrl);
    final uri = Uri.tryParse(pairUrl);
    final onPhone = uri != null && _isLoopback(uri.host.toLowerCase());
    if (onPhone) {
      const title = 'This phone\'s server on Wi-Fi';
      if (!(localServerOnWifi ?? ApiConfig.localServerOnWifi)) {
        checks.add(const PairingCheck(
          title,
          PairingCheckState.fail,
          'This app uses the server running on this phone. In Server Management turn on "Let VR headsets on this Wi-Fi '
          'connect", Restart the server, then try again.',
        ));
        return PairingResult(checks);
      }
      final addresses = await (wifiAddresses ?? phoneWifiAddresses)();
      if (addresses.isEmpty) {
        checks.add(const PairingCheck(
          title,
          PairingCheckState.fail,
          'This phone has no Wi-Fi address. Join the Wi-Fi the headset uses (or turn on the phone\'s hotspot and join it '
          'from the headset).',
        ));
        return PairingResult(checks);
      }
      pairUrl = uri.replace(host: addresses.first).toString();
      pairUrl = _trimmed(pairUrl);
      name = 'Phone server (${addresses.first})';
      checks.add(PairingCheck(
        title,
        PairingCheckState.warn,
        'The headset will use $pairUrl. Keep this phone awake and on this Wi-Fi; if its address changes, pair again.',
      ));
    }
    checks.add(checkAddress(pairUrl));
    if (checks.last.failed) return PairingResult(checks);
    final health = await checkHealth(client, pairUrl, apiKey);
    if (onPhone && health.failed) {
      checks.add(PairingCheck(
        health.title,
        PairingCheckState.fail,
        'The server does not answer on $pairUrl. Restart it from Server Management (the Wi-Fi setting applies when it starts).',
      ));
      return PairingResult(checks);
    }
    checks.add(health);
    if (health.failed) return PairingResult(checks);
    checks.add(await checkEndpoints(client, pairUrl, apiKey));
    if (checks.last.failed) return PairingResult(checks);
    return PairingResult(checks, pairUrl: pairUrl, name: name);
  }

  /// This phone's local-network IPv4 addresses, Wi-Fi (and hotspot) interfaces first. A mobile-data interface's address is left
  /// out: carriers hand out private 10.x addresses a headset cannot reach.
  static Future<List<String>> phoneWifiAddresses() async {
    final List<NetworkInterface> interfaces;
    try {
      interfaces = await NetworkInterface.list(type: InternetAddressType.IPv4);
    } catch (_) {
      return const [];
    }
    bool isWifi(String name) => RegExp(r'^(wlan|swlan|ap|softap|wl|en)').hasMatch(name.toLowerCase());
    bool isMobile(String name) => RegExp(r'^(rmnet|v4-rmnet|ccmni|pdp|dummy|tun|lo)').hasMatch(name.toLowerCase());
    final wifi = <String>[];
    final other = <String>[];
    for (final interface in interfaces) {
      if (isMobile(interface.name)) continue;
      for (final address in interface.addresses) {
        final host = address.address;
        if (_isLoopback(host) || host.startsWith('169.254.') || !_isLocalNetwork(host) || _isTailnet(host)) continue;
        (isWifi(interface.name) ? wifi : other).add(host);
      }
    }
    return [...wifi, ...other];
  }

  /// The QR code's text: `didsa-vr:1?n=<name>&u=<url>&k=<key>`, each value percent-encoded.
  static String payload({required String name, required String baseUrl, required String apiKey}) {
    final query = [
      'n=${Uri.encodeQueryComponent(name)}',
      'u=${Uri.encodeQueryComponent(_trimmed(baseUrl))}',
      'k=${Uri.encodeQueryComponent(apiKey.trim())}',
    ].join('&');
    return '$payloadScheme:$payloadVersion?$query';
  }

  /// The name the headset lists the server under: its host name.
  static String defaultName(String baseUrl) => Uri.tryParse(baseUrl.trim())?.host ?? 'DIDSA server';

  static String _trimmed(String url) {
    var out = url.trim();
    while (out.endsWith('/')) {
      out = out.substring(0, out.length - 1);
    }
    return out;
  }

  static bool _isLoopback(String host) =>
      host == 'localhost' || host.endsWith('.localhost') || host.startsWith('127.') || host == '::1' || host == '[::1]' ||
      host == '0.0.0.0';

  static List<int>? _ipv4(String host) {
    final parts = host.split('.');
    if (parts.length != 4) return null;
    final out = <int>[];
    for (final part in parts) {
      final value = int.tryParse(part);
      if (value == null || value < 0 || value > 255) return null;
      out.add(value);
    }
    return out;
  }

  static bool _isTailnet(String host) {
    if (host.endsWith('.ts.net')) return true;
    final ip = _ipv4(host);
    return ip != null && ip[0] == 100 && ip[1] >= 64 && ip[1] <= 127;
  }

  /// A private or local-network address: RFC 1918 ranges, Tailscale's range, an IPv6 unique-local address, a `.local` name, or
  /// a bare name with no dot (a machine name on the local network).
  static bool _isLocalNetwork(String host) {
    if (host.endsWith('.local') || host.endsWith('.lan') || host.endsWith('.home.arpa')) return true;
    if (_isTailnet(host)) return true;
    final ip = _ipv4(host);
    if (ip != null) {
      return ip[0] == 10 || (ip[0] == 172 && ip[1] >= 16 && ip[1] <= 31) || (ip[0] == 192 && ip[1] == 168);
    }
    if (host.contains(':')) return host.startsWith('fc') || host.startsWith('fd');
    return !host.contains('.');
  }
}
