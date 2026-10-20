import 'dart:convert';

import 'package:didsa_cad_client/vr_pairing/headset_pairing.dart';
import 'package:didsa_cad_client/vr_pairing/headset_pairing_screen.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:qr_flutter/qr_flutter.dart';

/// A backend that answers /health for [key] and serves an OpenAPI schema listing [paths].
MockClient _server({String key = 'secret', List<String>? paths, bool up = true}) {
  final listed = paths ?? [...HeadsetPairing.requiredPaths, ...HeadsetPairing.optionalPaths.keys];
  return MockClient((request) async {
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

    test('plain http is refused, on the internet and (for now) on the LAN', () {
      expect(stateOf('http://cad.example.net'), PairingCheckState.fail);
      expect(stateOf('http://192.168.1.20:8000'), PairingCheckState.fail);
      expect(stateOf('http://raspberrypi:8000'), PairingCheckState.fail);
      expect(HeadsetPairing.checkAddress('http://192.168.1.20:8000').message, contains('https://'));
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
      final checks = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      expect(checks.map((c) => c.state), everyElement(PairingCheckState.pass));
      expect(checks, hasLength(4));
    });

    test('no server set stops at the first check', () async {
      final checks = await HeadsetPairing.runChecks(client: _server(), baseUrl: '', apiKey: '');
      expect(checks.single.failed, isTrue);
    });

    test('a local address stops before any request is made', () async {
      var requests = 0;
      final client = MockClient((_) async {
        requests++;
        return http.Response('', 200);
      });
      final checks = await HeadsetPairing.runChecks(client: client, baseUrl: 'http://127.0.0.1:8000', apiKey: 'secret');
      expect(checks.last.failed, isTrue);
      expect(requests, 0);
    });

    test('a server that is down, or refuses the key, fails', () async {
      final down = await HeadsetPairing.runChecks(
        client: _server(up: false),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      expect(down.last.failed, isTrue);
      final wrongKey = await HeadsetPairing.runChecks(
        client: _server(),
        baseUrl: 'https://cad.example.net',
        apiKey: 'wrong',
      );
      expect(wrongKey.last.failed, isTrue);
      expect(wrongKey.last.message, contains('API key'));
    });

    test('a server missing a required endpoint is too old', () async {
      final checks = await HeadsetPairing.runChecks(
        client: _server(paths: ['/health']),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      expect(checks.last.failed, isTrue);
      expect(checks.last.message, contains('assembly-mesh.glb'));
    });

    test('a server without Scenes still pairs, with a warning naming it', () async {
      final checks = await HeadsetPairing.runChecks(
        client: _server(paths: [...HeadsetPairing.requiredPaths, '/document/parts/{part_id}/mates']),
        baseUrl: 'https://cad.example.net',
        apiKey: 'secret',
      );
      expect(checks.last.state, PairingCheckState.warn);
      expect(checks.last.message, allOf(contains('Scenes'), contains('Appearance')));
      expect(checks.any((c) => c.failed), isFalse);
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

    testWidgets('the on-phone server shows why, and no code', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: HeadsetPairingScreen(baseUrl: 'http://127.0.0.1:8000', apiKey: 'secret', httpClient: _server()),
      ));
      await tester.pumpAndSettle();
      expect(find.byType(QrImageView), findsNothing);
      expect(find.textContaining('runs on this device'), findsOneWidget);
      expect(find.text('Check again'), findsOneWidget);
      expect(find.text('Show the code'), findsNothing);
    });
  });
}
