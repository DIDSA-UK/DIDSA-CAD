// The home screen (three styles), its status lights, the tiles' behaviour, the settings wheel and the sub-menus' theme.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/config.dart';
import 'package:didsa_cad_client/home/home_screen.dart';
import 'package:didsa_cad_client/home/home_status.dart';
import 'package:didsa_cad_client/home/home_theme.dart';
import 'package:didsa_cad_client/home/server_screen.dart';

const _cad = 'https://cad.test';
const _store = 'https://store.test';

/// Answers /health for the CAD server and the cloud storage, each switchable.
class _Net {
  bool cadUp = true;
  int cadStatus = 200;
  bool storeUp = true;
  int storeStatus = 200;
  final List<String> calls = [];

  late final MockClient client = MockClient((request) async {
    calls.add('${request.url.host}${request.url.path}');
    if (request.url.host == 'cad.test') {
      if (!cadUp) throw http.ClientException('down');
      return http.Response(jsonEncode({'status': 'ok'}), cadStatus);
    }
    if (request.url.host == 'store.test') {
      if (!storeUp) throw http.ClientException('down');
      return http.Response(jsonEncode({'status': 'ok', 'api_features': <String>[]}), storeStatus);
    }
    return http.Response('no', 404);
  });
}

Future<void> _prefs({bool cad = true, bool store = true, HomeStyle style = HomeStyle.blueprint}) async {
  SharedPreferences.setMockInitialValues({
    if (cad) 'server_url': _cad,
    if (cad) 'api_key': 'cad-key',
    if (store) 'project_store_url': _store,
    if (store) 'project_store_api_key': 'store-key',
    'home_style': style.name,
  });
  await ApiConfig.load();
  await HomePreferences.load();
}

Future<void> _pump(WidgetTester tester, _Net net, {Widget Function(BuildContext)? mesh, Widget Function(BuildContext)? cadTools, Widget Function(BuildContext)? vr}) async {
  await tester.binding.setSurfaceSize(const Size(430, 900));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      home: HomeScreen(
        httpClient: net.client,
        meshViewerBuilder: mesh ?? (_) => const Scaffold(body: Text('mesh viewer opened')),
        toolChooserBuilder: cadTools ?? (_) => const Scaffold(body: Text('tool chooser opened')),
        headsetBuilder: vr ?? (_) => const Scaffold(body: Text('headset pairing opened')),
      ),
    ),
  );
  await _settle(tester);
}

Future<void> _settle(WidgetTester tester) async {
  for (var i = 0; i < 6; i++) {
    await tester.pump(const Duration(milliseconds: 100));
  }
}

Color _lightColor(WidgetTester tester, String id) {
  final light = tester.widget<StatusLight>(find.byKey(ValueKey('light-$id')));
  return light.color;
}

void main() {
  group('the three styles', () {
    for (final style in HomeStyle.values) {
      testWidgets('${style.name}: logo, the five tiles and the settings wheel', (tester) async {
        await _prefs(style: style);
        await _pump(tester, _Net());

        expect(find.byKey(const ValueKey('home-logo')), findsOneWidget);
        for (final id in ['mesh', 'cad', 'server', 'storage', 'vr']) {
          expect(find.byKey(ValueKey('tile-$id')), findsOneWidget, reason: '$id tile');
        }
        expect(find.byKey(const ValueKey('home-settings')), findsOneWidget);
        expect(find.text('Mesh tools'), findsOneWidget);
        expect(find.text('CAD tools'), findsOneWidget);
        expect(find.text('Server'), findsWidgets);
        expect(find.text('Storage'), findsWidgets);
        expect(find.text('Connect a VR headset'), findsOneWidget);
      });
    }

    testWidgets('each style has its own marks (a title block, status lamps) and background', (tester) async {
      await _prefs(style: HomeStyle.drawing);
      await _pump(tester, _Net());
      expect(find.byKey(const ValueKey('title-block')), findsOneWidget);
      expect(find.byKey(const ValueKey('led-server')), findsNothing);
      expect(tester.widget<Scaffold>(find.byType(Scaffold).first).backgroundColor ?? Theme.of(tester.element(find.byType(Scaffold).first)).scaffoldBackgroundColor, HomeTheme.drawing.background);

      await _prefs(style: HomeStyle.instrument);
      await _pump(tester, _Net());
      expect(find.byKey(const ValueKey('led-server')), findsOneWidget);
      expect(find.byKey(const ValueKey('led-storage')), findsOneWidget);
      expect(find.byKey(const ValueKey('title-block')), findsNothing);

      await _prefs(style: HomeStyle.blueprint);
      await _pump(tester, _Net());
      expect(find.byKey(const ValueKey('led-server')), findsNothing);
      expect(find.byKey(const ValueKey('title-block')), findsNothing);
    });

    for (final style in HomeStyle.values) {
      testWidgets('${style.name}: lays out at phone and desktop widths without overflow', (tester) async {
        await _prefs(style: style);
        for (final size in [const Size(360, 640), const Size(430, 900), const Size(1280, 800)]) {
          await tester.binding.setSurfaceSize(size);
          await tester.pumpWidget(MaterialApp(home: HomeScreen(httpClient: _Net().client)));
          await _settle(tester);
          expect(tester.takeException(), isNull, reason: '${style.name} at $size');
          expect(find.byKey(const ValueKey('tile-vr')), findsOneWidget);
        }
        addTearDown(() => tester.binding.setSurfaceSize(null));
      });
    }
  });

  group('status lights and greyed tiles', () {
    for (final style in HomeStyle.values) {
      testWidgets('${style.name}: connected server and online cloud storage are green, nothing is locked', (tester) async {
        await _prefs(style: style);
        await _pump(tester, _Net());
        final home = HomeTheme.of(style);
        expect(_lightColor(tester, 'server'), home.ok);
        expect(_lightColor(tester, 'storage'), home.ok);
        expect(find.byKey(const ValueKey('lock-cad')), findsNothing);
        expect(find.byKey(const ValueKey('lock-vr')), findsNothing);
      });

      testWidgets('${style.name}: no server and no cloud storage: grey lights; CAD tools and the headset are locked, mesh is not', (tester) async {
        await _prefs(cad: false, store: false, style: style);
        await _pump(tester, _Net());
        final home = HomeTheme.of(style);
        expect(_lightColor(tester, 'server'), home.neutral);
        expect(_lightColor(tester, 'storage'), home.neutral);
        expect(find.byKey(const ValueKey('lock-cad')), findsOneWidget);
        expect(find.byKey(const ValueKey('lock-vr')), findsOneWidget);
        expect(find.byKey(const ValueKey('lock-mesh')), findsNothing);
        expect(find.text('Not set up'), findsOneWidget);
        expect(find.text('Local folder'), findsOneWidget);
      });
    }

    testWidgets('a set-up server that does not answer is red, and so is cloud storage that does not answer', (tester) async {
      await _prefs();
      await _pump(tester, _Net()..cadUp = false..storeUp = false);
      expect(_lightColor(tester, 'server'), HomeTheme.blueprint.bad);
      expect(_lightColor(tester, 'storage'), HomeTheme.blueprint.bad);
      expect(find.text("Can't reach the server"), findsOneWidget);
      expect(find.text('Cloud storage · offline'), findsOneWidget);
      expect(find.byKey(const ValueKey('lock-cad')), findsOneWidget);
    });

    testWidgets('a refused key reads as such (server 401, cloud storage 401)', (tester) async {
      await _prefs();
      await _pump(tester, _Net()..cadStatus = 401..storeStatus = 401);
      expect(find.text('Server refused the key'), findsOneWidget);
      expect(find.text('Cloud storage refused the key'), findsOneWidget);
    });

    testWidgets('while the first look is in progress nothing is greyed out', (tester) async {
      await _prefs();
      await tester.pumpWidget(MaterialApp(home: HomeScreen(httpClient: MockClient((r) async => Future<http.Response>.delayed(const Duration(seconds: 3), () => http.Response('{}', 200))))));
      await tester.pump(const Duration(milliseconds: 200));
      expect(find.byKey(const ValueKey('lock-cad')), findsNothing);
      expect(find.text('Checking…'), findsWidgets);
      await tester.pump(const Duration(seconds: 4));
    });
  });

  group('what the tiles do', () {
    testWidgets('Mesh tools opens with no server at all', (tester) async {
      await _prefs(cad: false, store: false);
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('tile-mesh')));
      await _settle(tester);
      expect(find.text('mesh viewer opened'), findsOneWidget);
    });

    testWidgets('CAD tools and the headset open when the server answers', (tester) async {
      await _prefs();
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('tile-cad')));
      await _settle(tester);
      expect(find.text('tool chooser opened'), findsOneWidget);
      Navigator.of(tester.element(find.text('tool chooser opened'))).pop();
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('tile-vr')));
      await _settle(tester);
      expect(find.text('headset pairing opened'), findsOneWidget);
    });

    testWidgets('a greyed CAD tools tile still answers: it opens Server with the reason, and says what to do', (tester) async {
      await _prefs(cad: false);
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('tile-cad')));
      await _settle(tester);
      expect(find.byType(ServerScreen), findsOneWidget);
      expect(find.text('Connect a server to use CAD tools.'), findsOneWidget);
      expect(find.text('tool chooser opened'), findsNothing);
    });

    testWidgets('a greyed headset tile with an unreachable server says it is not answering', (tester) async {
      await _prefs();
      await _pump(tester, _Net()..cadUp = false);
      await tester.tap(find.byKey(const ValueKey('tile-vr')));
      await _settle(tester);
      expect(find.byType(ServerScreen), findsOneWidget);
      expect(find.textContaining("isn't answering"), findsOneWidget);
      expect(find.textContaining('a VR headset'), findsOneWidget);
    });

    testWidgets('a stale light is looked at again on tap: a server that came back opens the tool chooser', (tester) async {
      await _prefs();
      final net = _Net()..cadUp = false;
      await _pump(tester, net);
      expect(find.byKey(const ValueKey('lock-cad')), findsOneWidget);
      net.cadUp = true;
      await tester.tap(find.byKey(const ValueKey('tile-cad')));
      await _settle(tester);
      expect(find.text('tool chooser opened'), findsOneWidget);
    });

    testWidgets('Connect on the Server screen saves, returns home and turns the light green', (tester) async {
      await _prefs(cad: false, store: false);
      final net = _Net();
      await _pump(tester, net);
      expect(_lightColor(tester, 'server'), HomeTheme.blueprint.neutral);

      await tester.tap(find.byKey(const ValueKey('tile-server')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('server-url-field')), _cad);
      await tester.enterText(find.byKey(const ValueKey('server-key-field')), 'cad-key');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await _settle(tester);
      await _settle(tester);

      expect(ApiConfig.baseUrl, _cad);
      expect(ApiConfig.apiKey, 'cad-key');
      expect(find.byType(ServerScreen), findsNothing);
      expect(_lightColor(tester, 'server'), HomeTheme.blueprint.ok);
      expect(find.byKey(const ValueKey('lock-cad')), findsNothing);
    });

    testWidgets('a wrong address on the Server screen saves nothing', (tester) async {
      await _prefs(cad: false, store: false);
      await _pump(tester, _Net()..cadUp = false);
      await tester.tap(find.byKey(const ValueKey('tile-server')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('server-url-field')), _cad);
      await tester.enterText(find.byKey(const ValueKey('server-key-field')), 'k');
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('server-error')), findsOneWidget);
      expect(ApiConfig.baseUrl, '');
    });

    testWidgets('the Server screen keeps Use Local Server and Server Management', (tester) async {
      await _prefs(cad: false, store: false);
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('tile-server')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('use-local-server')), findsOneWidget);
      expect(find.byKey(const ValueKey('server-management')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('use-local-server')));
      await tester.pump();
      expect(find.textContaining('No local server key recorded yet'), findsOneWidget);
    });

    testWidgets('Storage opens with the local folder and the cloud storage settings', (tester) async {
      await _prefs();
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('tile-storage')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('choose-local-folder')), findsOneWidget);
      expect(find.byKey(const ValueKey('store-url-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('store-key-field')), findsOneWidget);
      expect(find.byKey(const ValueKey('device-name-field')), findsOneWidget);
    });
  });

  group('the settings wheel and the style', () {
    testWidgets('lists the three styles and the tools settings that used to be gears on the old screen', (tester) async {
      await _prefs();
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('home-settings')));
      await _settle(tester);
      for (final style in HomeStyle.values) {
        expect(find.byKey(ValueKey('style-${style.name}')), findsOneWidget);
      }
      expect(find.byKey(const ValueKey('settings-sketcher')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-mesh-viewer')), findsOneWidget);
      expect(find.byKey(const ValueKey('settings-controls')), findsOneWidget);
    });

    testWidgets('choosing a style changes the home screen, and is remembered', (tester) async {
      await _prefs();
      await _pump(tester, _Net());
      expect(find.byKey(const ValueKey('title-block')), findsNothing);

      await tester.tap(find.byKey(const ValueKey('home-settings')));
      await _settle(tester);
      await tester.tap(find.byKey(const ValueKey('style-drawing')));
      await _settle(tester);
      expect(HomePreferences.style.value, HomeStyle.drawing);
      expect((await SharedPreferences.getInstance()).getString('home_style'), 'drawing');

      Navigator.of(tester.element(find.byKey(const ValueKey('style-drawing')))).pop();
      await _settle(tester);
      expect(find.byKey(const ValueKey('title-block')), findsOneWidget);

      // A later launch starts in the style chosen.
      HomePreferences.style.value = HomeStyle.blueprint;
      await HomePreferences.load();
      expect(HomePreferences.style.value, HomeStyle.drawing);
    });

    testWidgets('an unknown remembered style falls back to Blueprint', (tester) async {
      SharedPreferences.setMockInitialValues({'home_style': 'neon'});
      await HomePreferences.load();
      expect(HomePreferences.style.value, HomeStyle.blueprint);
    });
  });

  group('sub-menus match the style', () {
    for (final style in HomeStyle.values) {
      testWidgets('${style.name}: Server, Storage and Settings use its palette', (tester) async {
        await _prefs(style: style);
        await _pump(tester, _Net());
        final home = HomeTheme.of(style);

        Color scaffold(Finder inside) => Theme.of(tester.element(inside)).scaffoldBackgroundColor;
        Color accent(Finder inside) => Theme.of(tester.element(inside)).colorScheme.primary;

        await tester.tap(find.byKey(const ValueKey('tile-server')));
        await _settle(tester);
        expect(scaffold(find.byKey(const ValueKey('server-url-field'))), home.background);
        expect(accent(find.byKey(const ValueKey('server-connect'))), home.accent);
        expect(Theme.of(tester.element(find.byKey(const ValueKey('server-url-field')))).brightness, home.brightness);
        Navigator.of(tester.element(find.byKey(const ValueKey('server-url-field')))).pop();
        await _settle(tester);

        await tester.tap(find.byKey(const ValueKey('tile-storage')));
        await _settle(tester);
        expect(scaffold(find.byKey(const ValueKey('store-url-field'))), home.background);
        Navigator.of(tester.element(find.byKey(const ValueKey('store-url-field')))).pop();
        await _settle(tester);

        await tester.tap(find.byKey(const ValueKey('home-settings')));
        await _settle(tester);
        expect(scaffold(find.byKey(const ValueKey('style-blueprint'))), home.background);
      });
    }

    testWidgets('changing the style is live in an open sub-menu', (tester) async {
      await _prefs();
      await _pump(tester, _Net());
      await tester.tap(find.byKey(const ValueKey('home-settings')));
      await _settle(tester);
      expect(Theme.of(tester.element(find.byKey(const ValueKey('style-drawing')))).brightness, Brightness.dark);
      await tester.tap(find.byKey(const ValueKey('style-drawing')));
      await _settle(tester);
      expect(Theme.of(tester.element(find.byKey(const ValueKey('style-drawing')))).brightness, Brightness.light);
    });
  });

  group('HomeStatusController', () {
    test('reports each light and a short line for each', () async {
      await _prefs();
      final net = _Net();
      final controller = HomeStatusController(httpClient: net.client);
      await controller.refresh();
      expect(controller.value.server, ServerLight.connected);
      expect(controller.value.storage, StorageLight.online);
      expect(controller.value.serverDetail, contains('cad.test'));
      expect(controller.value.serverUsable, isTrue);

      net.cadUp = false;
      net.storeStatus = 500;
      await controller.refresh();
      expect(controller.value.server, ServerLight.unreachable);
      expect(controller.value.storage, StorageLight.offline);
      expect(controller.value.serverUsable, isFalse);
      controller.dispose();
    });

    test('nothing set up: grey, and no request is made', () async {
      await _prefs(cad: false, store: false);
      final net = _Net();
      final controller = HomeStatusController(httpClient: net.client);
      await controller.refresh();
      expect(controller.value.server, ServerLight.notSetUp);
      expect(controller.value.storage, StorageLight.localOnly);
      expect(net.calls, isEmpty);
      controller.dispose();
    });

    test('notifies only when something changed', () async {
      await _prefs();
      final controller = HomeStatusController(httpClient: _Net().client);
      var notified = 0;
      controller.addListener(() => notified++);
      await controller.refresh();
      await controller.refresh();
      expect(notified, 1);
      controller.dispose();
    });
  });
}
