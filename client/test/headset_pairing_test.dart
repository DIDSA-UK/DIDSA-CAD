import 'dart:convert';

import 'package:didsa_cad_client/vr_pairing/headset_pairing.dart';
import 'package:didsa_cad_client/vr_pairing/headset_pairing_screen.dart';
import 'package:material_ui/material_ui.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A backend that answers /health for [key] and serves an OpenAPI schema listing [paths]. [relay], when given, answers every request
/// on port 8100 (the browser relay's).
MockClient _server({
  String key = 'secret',
  List<String>? paths,
  bool up = true,
  List<String>? hosts,
  Future<http.Response> Function(http.Request request)? relay,
}) {
  final listed = paths ?? [...HeadsetPairing.requiredPaths, ...HeadsetPairing.optionalPaths.keys];
  return MockClient((request) async {
    hosts?.add(request.url.host);
    if (relay != null && request.url.port == 8100) return relay(request);
    if (!up) throw http.ClientException('connection refused');
    if (request.url.path == '/health') {
      return request.headers['X-API-Key'] == key ? http.Response('{"status":"ok"}', 200) : http.Response('', 401);
    }
    if (request.url.path == '/openapi.json') {
      return http.Response(jsonEncode({'paths': {for (final p in listed) p: {}}}), 200);
    }
    return http.Response('', 404);
  });
}

void main() {
  group('checkAddress', () {
    PairingCheckState stateOf(String url) => HeadsetPairing.checkAddress(url).state;

    test('a public https address passes', () {
      expect(stateOf('https://cad-api.example.net'), PairingCheckState.pass);
    });

    test('the on-phone local server is refused', () {
      expect(stateOf('http://127.0.0.1:8000'), PairingCheckState.fail);
      expect(stateOf('http://localhost:8000'), PairingCheckState.fail);
      expect(stateOf('https://localhost'), PairingCheckState.fail);
      expect(stateOf('http://[::1]:8000'), PairingCheckState.fail);
      expect(HeadsetPairing.checkAddress('http://127.0.0.1:8000').message, contains('this device'));
    });

    test('emulator and link-local addresses are refused', () {
      expect(stateOf('http://10.0.2.2:8000'), PairingCheckState.fail);
      expect(stateOf('http://169.254.10.2:8000'), PairingCheckState.fail);
    });

    test('plain http is refused on the internet, allowed with a warning on the local network', () {
      expect(stateOf('http://cad.example.net'), PairingCheckState.fail);
      expect(stateOf('http://192.168.1.20:8000'), PairingCheckState.warn);
      expect(stateOf('http://10.1.2.3:8000'), PairingCheckState.warn);
      expect(stateOf('http://raspberrypi:8000'), PairingCheckState.warn);
      expect(HeadsetPairing.checkAddress('http://192.168.1.20:8000').message, contains('unencrypted'));
    });

    test('local https, .local and Tailscale addresses pass with a warning', () {
      expect(stateOf('https://192.168.1.20'), PairingCheckState.warn);
      expect(stateOf('https://cad.local'), PairingCheckState.warn);
      expect(stateOf('https://box.tail1234.ts.net'), PairingCheckState.warn);
      expect(stateOf('https://100.101.2.3'), PairingCheckState.warn);
    });

    test('nonsense is refused', () {
      expect(stateOf('not a url'), PairingCheckState.fail);
      expect(stateOf('ftp://cad.example.net'), PairingCheckState.fail);
      expect(stateOf(''), PairingCheckState.fail);
    });
  });

  group('runChecks', () {
    test('all pass against a current server', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      final checks = result.checks;
      expect(checks.map((c) => c.state), everyElement(PairingCheckState.pass));
      expect(checks, hasLength(4));
    });

    test('no server set stops at the first check', () async {
      final result = await HeadsetPairing.runChecks(client: _server(), baseUrl: '', apiKey: '');
      final checks = result.checks;
      expect(checks.single.failed, isTrue);
    });

    test('a local address stops before any request is made', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      final result = await HeadsetPairing.runChecks(
        client: client,
        baseUrl: 'http://127.0.0.1:8000',
        apiKey: 'secret',
        localServerOnWifi: false,
      );
      final checks = result.checks;
      expect(checks.last.failed, isTrue);
      expect(requests, 0);
    });

    test('a server that is down, or refuses the key, fails', () async {
      final down = (await HeadsetPairing.runChecks(
        client: _server(up: false),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      ))
          .checks;
      expect(down.last.failed, isTrue);
      final wrongKey = (await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'https://cad.example.net',
        apiKey: 'wrong',
      ))
          .checks;
      expect(wrongKey.last.failed, isTrue);
      expect(wrongKey.last.message, contains('API key'));
    });

    test('a server missing a required endpoint is too old', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(paths: ['/health']),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      final checks = result.checks;
      expect(checks.last.failed, isTrue);
      expect(checks.last.message, contains('assembly-mesh.glb'));
    });

    test('a server without Scenes still pairs, with a warning naming it', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(paths: [...HeadsetPairing.requiredPaths, '/document/parts/{part_id}/mates']),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      final checks = result.checks;
      expect(checks.last.state, PairingCheckState.warn);
      expect(checks.last.message, allOf(contains('Scenes'), contains('Appearance')));
      expect(checks.any((c) => c.failed), isFalse);
    });
  });

  group('the on-phone server', () {
    test('is refused until it listens on Wi-Fi', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'http://127.0.0.1:8000',
        apiKey: 'secret',
        localServerOnWifi: false,
        wifiAddresses: () async => ['192.168.1.5'],
      );
      expect(result.compatible, isFalse);
      expect(result.checks.last.message, contains('Let VR headsets on this Wi-Fi connect'));
    });

    test('is refused with no Wi-Fi address', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'http://127.0.0.1:8000',
        apiKey: 'secret',
        localServerOnWifi: true,
        wifiAddresses: () async => [],
      );
      expect(result.compatible, isFalse);
      expect(result.checks.last.message, contains('no Wi-Fi address'));
    });

    test('pairs at the phone\'s Wi-Fi address, checked there, not at 127.0.0.1', () async {
      final asked = <String>[];
      final client = _server(hosts: asked);
      final result = await HeadsetPairing.runChecks(
        client: client,
        baseUrl: 'http://127.0.0.1:8000/',
        apiKey: 'secret',
        localServerOnWifi: true,
        wifiAddresses: () async => ['192.168.1.5', '10.0.0.7'],
      );
      expect(result.compatible, isTrue);
      expect(result.pairUrl, 'http://192.168.1.5:8000');
      expect(result.name, 'Phone server (192.168.1.5)');
      expect(asked, everyElement('192.168.1.5'));
      expect(asked, isNotEmpty);
      final payload = HeadsetPairing.payload(name: result.name, baseUrl: result.pairUrl!, apiKey: 'secret');
      expect(Uri.splitQueryString(payload.substring(payload.indexOf('?') + 1))['u'], 'http://192.168.1.5:8000');
    });

    test('says to restart when the server is not listening on Wi-Fi yet', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(up: false),
        baseUrl: 'http://127.0.0.1:8000',
        apiKey: 'secret',
        localServerOnWifi: true,
        wifiAddresses: () async => ['192.168.1.5'],
      );
      expect(result.compatible, isFalse);
      expect(result.checks.last.message, allOf(contains('192.168.1.5'), contains('Restart')));
    });
  });

  group('browser relay', () {
    test('ws:// on the local network and wss:// are put in the code; http(s) is taken as ws(s); /ws is dropped', () {
      expect(HeadsetPairing.checkRelayAddress('ws://192.168.1.20:8100').$2, 'ws://192.168.1.20:8100');
      expect(HeadsetPairing.checkRelayAddress('ws://192.168.1.20:8100').$1.state, PairingCheckState.warn);
      expect(HeadsetPairing.checkRelayAddress('wss://relay.example.net/ws/').$2, 'wss://relay.example.net');
      expect(HeadsetPairing.checkRelayAddress('wss://relay.example.net').$1.state, PairingCheckState.pass);
      expect(HeadsetPairing.checkRelayAddress('http://192.168.1.20:8100').$2, 'ws://192.168.1.20:8100');
      expect(HeadsetPairing.checkRelayAddress('https://relay.example.net').$2, 'wss://relay.example.net');
    });

    test('an address the headset would refuse is left out, with a warning, never a failure', () {
      for (final url in ['ws://relay.example.net', 'ws://127.0.0.1:8100', 'ftp://192.168.1.20']) {
        final (check, wsUrl) = HeadsetPairing.checkRelayAddress(url);
        expect(wsUrl, isNull, reason: url);
        expect(check.state, PairingCheckState.warn, reason: url);
      }
      expect(HeadsetPairing.checkRelayAddress('ws://relay.example.net').$1.message, contains('ws://'));
    });

    test('runChecks: the relay rides along, checked at its /health over http; a dead relay only warns', () async {
      final asked = <String>[];
      final client = _server(relay: (request) async {
        asked.add(request.url.toString());
        return http.Response('{"status":"ok"}', 200);
      });
      final result = await HeadsetPairing.runChecks(
        client: client,
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
        relayUrl: 'wss://relay.example.net:8100',
        relayApiKey: 'rk',
      );
      expect(result.compatible, isTrue);
      expect(result.relayUrl, 'wss://relay.example.net:8100');
      expect(asked, contains('https://relay.example.net:8100/health'));
      expect(result.checks.last.title, 'Browser relay running');
      expect(result.checks.last.state, PairingCheckState.pass);

      final down = await HeadsetPairing.runChecks(
        client: _server(relay: (request) async => throw http.ClientException('refused')),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
        relayUrl: 'wss://relay.example.net:8100',
        relayApiKey: 'rk',
      );
      expect(down.compatible, isTrue);
      expect(down.relayUrl, 'wss://relay.example.net:8100');
      expect(down.checks.last.state, PairingCheckState.warn);
    });

    test('runChecks: a relay with no key is left out', () async {
      final result = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
        relayUrl: 'wss://relay.example.net',
      );
      expect(result.compatible, isTrue);
      expect(result.relayUrl, isNull);
      expect(result.checks.last.title, 'Browser relay key');
    });

    test('runChecks: no relay set adds no relay check', () async {
      final result = await HeadsetPairing.runChecks(client: _server(), baseUrl: 'https://cad.example.net', apiKey: 'secret');
      expect(result.relayUrl, isNull);
      expect(result.checks.any((c) => c.title.startsWith('Browser relay')), isFalse);
    });
  });

  group('payload', () {
    test('is versioned and round-trips through Uri', () {
      final text = HeadsetPairing.payload(
        name: 'Workshop PC',
        baseUrl: 'https://cad.example.net/',
        apiKey: 'a b&c=d',
      );
      expect(text, startsWith('didsa-vr:1?'));
      final query = Uri.splitQueryString(text.substring(text.indexOf('?') + 1));
      expect(query, {'n': 'Workshop PC', 'u': 'https://cad.example.net', 'k': 'a b&c=d'});
    });

    test('carries the browser relay and its key when both are given, and neither otherwise', () {
      Map<String, String> query(String text) => Uri.splitQueryString(text.substring(text.indexOf('?') + 1));
      final withRelay = HeadsetPairing.payload(
        name: 'Pi',
        baseUrl: 'http://192.168.1.20:8000',
        apiKey: 'k',
        relayUrl: 'ws://192.168.1.20:8100',
        relayApiKey: 'r k',
      );
      expect(query(withRelay)['r'], 'ws://192.168.1.20:8100');
      expect(query(withRelay)['rk'], 'r k');
      final noKey = HeadsetPairing.payload(name: 'Pi', baseUrl: 'http://192.168.1.20:8000', apiKey: 'k', relayUrl: 'ws://192.168.1.20:8100');
      expect(query(noKey).containsKey('r'), isFalse);
      expect(query(noKey).containsKey('rk'), isFalse);
    });

    test('the default name is the host', () {
      expect(HeadsetPairing.defaultName('https://cad.example.net:8443/x'), 'cad.example.net');
    });
  });

  group('HeadsetPairingScreen', () {
    testWidgets('a compatible server shows the code, which hides itself', (tester) async {
      // Tall enough that the list builds everything below the code (it is a lazy ListView).
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        home: HeadsetPairingScreen(
          baseUrl: 'https://cad.example.net',
          apiKey: 'secret',
          httpClient: _server(),
          showFor: const Duration(seconds: 3),
        ),
      ));
      // Not pumpAndSettle: the countdown's own once-a-second rebuilds would run it down while settling.
      await tester.pump();
      await tester.pump();
      expect(find.byKey(const ValueKey('headset-pairing-qr')), findsOneWidget);
      final qr = tester.widget<QrImageView>(find.byType(QrImageView));
      expect(qr, isNotNull);
      expect(find.text('Hides in 3 s'), findsOneWidget);

      await tester.pump(const Duration(seconds: 3));
      expect(find.byType(QrImageView), findsNothing);
      expect(find.text('Show the code'), findsOneWidget);

      await tester.tap(find.text('Show the code'));
      await tester.pump();
      expect(find.byType(QrImageView), findsOneWidget);
      await tester.tap(find.text('Hide now'));
      await tester.pump();
      expect(find.byType(QrImageView), findsNothing);
    });

    testWidgets('a relay typed and saved goes into the code', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      final saved = <List<String>>[];
      await tester.pumpWidget(MaterialApp(
        home: HeadsetPairingScreen(
          baseUrl: 'https://cad.example.net',
          apiKey: 'secret',
          httpClient: _server(relay: (request) async => http.Response('{"status":"ok"}', 200)),
          relayUrl: '',
          relayApiKey: '',
          saveRelay: (url, key) async => saved.add([url, key]),
        ),
      ));
      await tester.pump();
      await tester.pump();
      String qrText() => tester.widget<MetaData>(find.byKey(const ValueKey('headset-pairing-payload'))).metaData as String;
      expect(qrText(), isNot(contains('rk=')));
      await tester.ensureVisible(find.text('Browser relay (optional)'));
      await tester.pump();
      await tester.tap(find.text('Browser relay (optional)'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byKey(const ValueKey('headset-pairing-relay-url')), 'wss://relay.example.net:8100');
      await tester.enterText(find.byKey(const ValueKey('headset-pairing-relay-key')), 'relaysecret');
      await tester.ensureVisible(find.text('Save relay and check again'));
      await tester.pump();
      await tester.tap(find.text('Save relay and check again'));
      await tester.pump();
      await tester.pump();
      await tester.pump();
      expect(saved, [
        ['wss://relay.example.net:8100', 'relaysecret'],
      ]);
      final query = Uri.splitQueryString(qrText().substring(qrText().indexOf('?') + 1));
      expect(query['r'], 'wss://relay.example.net:8100');
      expect(query['rk'], 'relaysecret');
    });

    testWidgets('the on-phone server shows why, and no code', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HeadsetPairingScreen(
          baseUrl: 'http://127.0.0.1:8000',
          apiKey: 'secret',
          httpClient: _server(),
          localServerOnWifi: false,
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('Let VR headsets on this Wi-Fi'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Show the code'), findsNothing);
    });
  });
}
