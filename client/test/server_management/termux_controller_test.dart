import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/config.dart';
import 'package:didsa_cad_client/server_management/termux_controller.dart';

/// [TermuxController.checkStatus]/[TermuxController.check] against a
/// [MockClient] - no real network, no device, no Termux (same rationale as
/// termux_commands_test.dart for the command-building side of this
/// feature).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await ApiConfig.load();
    await ApiConfig.saveLocalApiKey('local-test-key');
  });

  test('checkStatus reports reachable and parses git_branch from a 2xx body', () async {
    final client = MockClient((request) async {
      expect(request.headers['X-API-Key'], 'local-test-key');
      return http.Response(jsonEncode({'status': 'ok', 'git_branch': 'main'}), 200);
    });
    final controller = TermuxController(httpClient: client);

    final status = await controller.checkStatus();

    expect(status.reachability, ServerReachability.reachable);
    expect(status.branch, 'main');
  });

  test('checkStatus is still reachable with branch null if the field is missing', () async {
    final client = MockClient((request) async => http.Response(jsonEncode({'status': 'ok'}), 200));
    final controller = TermuxController(httpClient: client);

    final status = await controller.checkStatus();

    expect(status.reachability, ServerReachability.reachable);
    expect(status.branch, isNull);
  });

  test('checkStatus is still reachable with branch null if the body is not valid JSON', () async {
    final client = MockClient((request) async => http.Response('not json', 200));
    final controller = TermuxController(httpClient: client);

    final status = await controller.checkStatus();

    expect(status.reachability, ServerReachability.reachable);
    expect(status.branch, isNull);
  });

  test('checkStatus reports unreachable on a non-2xx response', () async {
    final client = MockClient((request) async => http.Response('', 401));
    final controller = TermuxController(httpClient: client);

    final status = await controller.checkStatus();

    expect(status.reachability, ServerReachability.unreachable);
    expect(status.branch, isNull);
  });

  test('checkStatus reports unreachable when the request throws', () async {
    final client = MockClient((request) async => throw Exception('connection refused'));
    final controller = TermuxController(httpClient: client);

    final status = await controller.checkStatus();

    expect(status.reachability, ServerReachability.unreachable);
    expect(status.branch, isNull);
  });

  test('check returns just the reachability half of checkStatus', () async {
    final client = MockClient((request) async => http.Response(jsonEncode({'git_branch': 'main'}), 200));
    final controller = TermuxController(httpClient: client);

    expect(await controller.check(), ServerReachability.reachable);
  });
}
