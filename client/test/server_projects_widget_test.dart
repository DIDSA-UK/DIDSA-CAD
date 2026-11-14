// Widgets of the server projects feature (S2): the store section of the server settings, the Server projects list, the conflict
// dialog and the sync chip, against the fake store. The service logic itself is `remote_storage_service_test.dart`.
import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/assembly/save_all.dart' show ChangedOnDiskChoice;
import 'package:didsa_cad_client/config.dart';
import 'package:didsa_cad_client/home/server_screen.dart';
import 'package:didsa_cad_client/home/storage_screen.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/server/remote_storage_service.dart';
import 'package:didsa_cad_client/storage/server/server_projects_dialog.dart';
import 'package:didsa_cad_client/storage/server/server_sync_chip.dart';
import 'package:didsa_cad_client/storage/server/store_client.dart';
import 'package:didsa_cad_client/storage/server/sync_conflict_dialog.dart';
import 'package:didsa_cad_client/storage/server/sync_conflicts.dart';
import 'package:didsa_cad_client/storage/server/sync_state.dart';

import 'support/fake_project_store.dart';
import 'support/in_memory_stores.dart';

RemoteStorageService _service(FakeProjectStore store, {String key = 'store-key'}) => RemoteStorageService(
      settings: () => StoreSettings(url: 'https://store.test', apiKey: key, deviceName: 'Desktop'),
      httpClient: store.client,
      syncStore: InMemorySyncStore(),
      fileCache: InMemoryFileCache(),
    );

Uint8List _file(String id) => Uint8List.fromList(utf8.encode(jsonEncode({
      'schema_version': 1,
      'document': {'id': 'd-$id', 'root_part_id': id, 'parts': [{'id': id, 'name': id, 'features': [], 'occurrences': [], 'mates': []}]},
      'sketches': [],
    })));

Future<void> _settle(WidgetTester tester) async {
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void main() {
  group('cloud storage settings (the Storage screen)', () {
    setUp(() async {
      SharedPreferences.setMockInitialValues({'server_url': 'https://cad.test', 'api_key': 'cad-key'});
      await ApiConfig.load();
    });

    Future<void> pumpScreen(WidgetTester tester, Widget screen) async {
      await tester.binding.setSurfaceSize(const Size(800, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => screen)),
                child: const Text('open screen'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open screen'));
      await _settle(tester);
    }

    testWidgets('S4: the room for local copies is shown (1024 MB by default), saved, and 0 means no limit', (tester) async {
      final store = FakeProjectStore();
      await pumpScreen(tester, StorageScreen(httpClient: store.client));
      expect(find.widgetWithText(TextField, '1024'), findsOneWidget);
      await tester.enterText(find.byKey(const ValueKey('store-url-field')), 'https://store.test');
      await tester.enterText(find.byKey(const ValueKey('store-key-field')), 'store-key');
      await tester.enterText(find.byKey(const ValueKey('cache-limit-field')), '300');
      await tester.tap(find.byKey(const ValueKey('store-save-button')));
      await _settle(tester);
      expect(ApiConfig.cacheLimitMb, 300);
      await tester.enterText(find.byKey(const ValueKey('cache-limit-field')), '0');
      await tester.tap(find.byKey(const ValueKey('store-save-button')));
      await _settle(tester);
      expect(ApiConfig.cacheLimitMb, 0);
      await tester.enterText(find.byKey(const ValueKey('cache-limit-field')), 'lots');
      await tester.tap(find.byKey(const ValueKey('store-save-button')));
      await _settle(tester);
      expect(ApiConfig.cacheLimitMb, 0, reason: 'text that is not a number leaves the setting as it was');
      await ApiConfig.saveCacheLimitMb(1024);
    });

    testWidgets('the address, key and device name are entered once and saved, and cloud storage is checked', (tester) async {
      final store = FakeProjectStore();
      await pumpScreen(tester, StorageScreen(httpClient: store.client));

      await tester.enterText(find.byKey(const ValueKey('store-url-field')), 'https://store.test/');
      await tester.enterText(find.byKey(const ValueKey('store-key-field')), 'store-key');
      await tester.enterText(find.byKey(const ValueKey('device-name-field')), 'Studio laptop');
      await tester.tap(find.byKey(const ValueKey('store-save-button')));
      await _settle(tester);

      expect(ApiConfig.storeUrl, 'https://store.test', reason: 'a trailing slash is dropped');
      expect(ApiConfig.storeApiKey, 'store-key');
      expect(ApiConfig.deviceName, 'Studio laptop');
      expect(ApiConfig.effectiveDeviceName, 'Studio laptop');
      expect(ApiConfig.storeConfigured, isTrue);
      expect(find.byKey(const ValueKey('store-message')), findsOneWidget);
      expect(find.textContaining('Cloud storage answered'), findsOneWidget);
      expect(store.devices.last, 'Studio laptop');
    });

    testWidgets('a wrong key is saved but reported', (tester) async {
      final store = FakeProjectStore(apiKey: 'right');
      await pumpScreen(tester, StorageScreen(httpClient: store.client));
      await tester.enterText(find.byKey(const ValueKey('store-url-field')), 'https://store.test');
      await tester.enterText(find.byKey(const ValueKey('store-key-field')), 'wrong');
      await tester.tap(find.byKey(const ValueKey('store-save-button')));
      await _settle(tester);
      expect(find.textContaining('refused the key'), findsOneWidget);
      expect(ApiConfig.storeApiKey, 'wrong');
    });

    testWidgets('the device name defaults to the platform when none is set', (tester) async {
      expect(ApiConfig.deviceName, '');
      expect(ApiConfig.effectiveDeviceName, isNotEmpty);
      expect(ApiConfig.effectiveDeviceName, ApiConfig.defaultDeviceName());
    });

    testWidgets('/health project_store is offered as the default cloud storage address (never a key)', (tester) async {
      final backend = MockClient((request) async {
        expect(request.url.path, '/health');
        return http.Response(jsonEncode({'status': 'ok', 'api_features': <String>[], 'project_store': 'https://store.example.com'}), 200);
      });
      await pumpScreen(tester, ServerScreen(httpClient: backend));
      expect(ApiConfig.storeUrl, '');

      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await _settle(tester);

      expect(ApiConfig.storeUrl, 'https://store.example.com');
      expect(ApiConfig.storeApiKey, '', reason: 'the backend never knows the store key: it is typed once');
      expect(ApiConfig.storeConfigured, isFalse);
    });

    testWidgets('an address already set is not replaced by what /health offers', (tester) async {
      await ApiConfig.saveStore(storeUrl: 'https://mine.example.com', storeApiKey: 'k');
      final backend = MockClient((request) async => http.Response(jsonEncode({'status': 'ok', 'project_store': 'https://store.example.com'}), 200));
      await pumpScreen(tester, ServerScreen(httpClient: backend));
      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await _settle(tester);
      expect(ApiConfig.storeUrl, 'https://mine.example.com');
    });

    testWidgets('a backend with no project_store (an older one) offers nothing', (tester) async {
      final backend = MockClient((request) async => http.Response(jsonEncode({'status': 'ok'}), 200));
      await pumpScreen(tester, ServerScreen(httpClient: backend));
      await tester.tap(find.byKey(const ValueKey('server-connect')));
      await _settle(tester);
      expect(ApiConfig.storeUrl, '');
    });
  });

  group('File > Server projects', () {
    testWidgets('lists the projects with their file counts and returns the one tapped', (tester) async {
      final store = FakeProjectStore();
      store.write('Gearbox', 'a.didsa', _file('p-a'));
      store.write('Gearbox', 'b.didsa', _file('p-b'));
      store.createProject('Bracket');
      final remote = _service(store);
      ServerProjectRoot? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () async => chosen = await showServerProjectsDialog(context, remote), child: const Text('go')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);

      expect(find.byKey(const ValueKey('server-projects-dialog')), findsOneWidget);
      expect(find.text('Bracket'), findsOneWidget);
      expect(find.text('Gearbox'), findsOneWidget);
      expect(find.textContaining('2 files'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('server-project-Gearbox')));
      await _settle(tester);
      expect(chosen, ServerProjectRoot(serverUrl: 'https://store.test', project: 'Gearbox'));
    });

    testWidgets('a new project can be made from the list', (tester) async {
      final store = FakeProjectStore();
      final remote = _service(store);
      ServerProjectRoot? chosen;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () async => chosen = await showServerProjectsDialog(context, remote), child: const Text('go')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(find.text('No projects in cloud storage yet.'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('new-server-project')));
      await _settle(tester);
      await tester.enterText(find.byKey(const ValueKey('new-server-project-name')), 'Fresh');
      await tester.tap(find.text('Create'));
      await _settle(tester);

      expect(chosen?.project, 'Fresh');
      expect(store.livePaths('Fresh'), isEmpty);
    });

    testWidgets('an unreachable store is said plainly, with Try again', (tester) async {
      final store = FakeProjectStore()..offline = true;
      final remote = _service(store);
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () => showServerProjectsDialog(context, remote), child: const Text('go')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(find.byKey(const ValueKey('server-projects-error')), findsOneWidget);
      expect(find.textContaining('could not be reached'), findsOneWidget);

      store.offline = false;
      store.createProject('Back');
      await tester.tap(find.text('Try again'));
      await _settle(tester);
      expect(find.text('Back'), findsOneWidget);
    });

    testWidgets('Open asks where: This device and Cloud storage are the two answers, and Cancel is neither', (tester) async {
      for (final entry in {'open-source-device': OpenSource.device, 'open-source-cloud': OpenSource.cloud}.entries) {
        OpenSource? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(onPressed: () async => result = await showOpenSourceDialog(context, cloudHost: 'storage-2.snail-shell.uk'), child: const Text('go')),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await _settle(tester);
        expect(find.text('storage-2.snail-shell.uk'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey(entry.key)));
        await _settle(tester);
        expect(result, entry.value);
      }
    });

    testWidgets('Copy to the server asks for the project name', (tester) async {
      String? name;
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => name = await showCopyToServerDialog(context, suggestedName: 'MyFolder'),
                child: const Text('go'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);
      expect(tester.widget<TextField>(find.byKey(const ValueKey('copy-to-server-name'))).controller!.text, 'MyFolder');
      await tester.enterText(find.byKey(const ValueKey('copy-to-server-name')), 'Renamed');
      await tester.tap(find.byKey(const ValueKey('copy-to-server-confirm')));
      await _settle(tester);
      expect(name, 'Renamed');
    });
  });

  group('the conflict dialog', () {
    final conflicts = [
      SyncConflict(
        path: 'parts/Shaft.didsa',
        clash: SyncClash(reason: 'changed', currentVersion: 3, modifiedBy: 'Quest 3', modifiedAt: DateTime.utc(2026, 11, 13, 14, 5)),
        queuedAt: DateTime.utc(2026, 11, 13, 14, 0),
      ),
      SyncConflict(
        path: 'Gearbox.didsa',
        clash: SyncClash(reason: 'deleted', currentVersion: 5, deleted: true, movedTo: 'Gearbox-v2.didsa', modifiedBy: 'Phone', modifiedAt: DateTime.utc(2026, 11, 13, 9, 30)),
        queuedAt: DateTime.utc(2026, 11, 13, 14, 0),
      ),
      SyncConflict(path: 'x.didsa', clash: const SyncClash(reason: 'path_conflict'), queuedAt: DateTime.utc(2026, 11, 13)),
    ];

    Future<Map<String, ConflictChoice>?> show(WidgetTester tester, List<SyncConflict> list, void Function(Map<String, ConflictChoice>?) done) async {
      await tester.binding.setSurfaceSize(const Size(900, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        MaterialApp(
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(onPressed: () async => done(await showSyncConflictDialog(context, list)), child: const Text('go')),
            ),
          ),
        ),
      );
      await tester.tap(find.text('go'));
      await _settle(tester);
      return null;
    }

    testWidgets('names who changed each file and when, a rename and a delete included', (tester) async {
      await show(tester, conflicts, (_) {});
      expect(find.byKey(const ValueKey('sync-conflict-dialog')), findsOneWidget);
      expect(tester.widget<Text>(find.byKey(const ValueKey('conflict-describe-parts/Shaft.didsa'))).data, startsWith('Changed by Quest 3 on 2026-11-13'));
      expect(tester.widget<Text>(find.byKey(const ValueKey('conflict-describe-Gearbox.didsa'))).data, startsWith('Renamed to Gearbox-v2.didsa by Phone'));
      expect(find.text('Nothing was written. Choose what to do with each file, then the save is sent again.'), findsOneWidget);
    });

    testWidgets('Apply waits until every file has a choice, then returns them per file', (tester) async {
      Map<String, ConflictChoice>? result;
      var called = false;
      await show(tester, conflicts.take(2).toList(), (r) {
        called = true;
        result = r;
      });
      FilledButton apply() => tester.widget<FilledButton>(find.byKey(const ValueKey('conflict-apply')));
      expect(apply().onPressed, isNull);

      await tester.tap(find.byKey(const ValueKey('conflict-keepMine-parts/Shaft.didsa')));
      await tester.pump();
      expect(apply().onPressed, isNull, reason: 'one file still undecided');
      await tester.tap(find.byKey(const ValueKey('conflict-saveCopy-Gearbox.didsa')));
      await tester.pump();
      expect(apply().onPressed, isNotNull);
      expect(find.textContaining('own Part id'), findsOneWidget, reason: 'the copy choice says it gets a new Part id');

      await tester.tap(find.byKey(const ValueKey('conflict-apply')));
      await _settle(tester);
      expect(called, isTrue);
      expect(result, {'parts/Shaft.didsa': ConflictChoice.keepMine, 'Gearbox.didsa': ConflictChoice.saveCopy});
    });

    testWidgets('each of the three choices can be picked', (tester) async {
      for (final choice in ConflictChoice.values) {
        Map<String, ConflictChoice>? result;
        await show(tester, conflicts.take(1).toList(), (r) => result = r);
        await tester.tap(find.byKey(ValueKey('conflict-${choice.name}-parts/Shaft.didsa')));
        await tester.pump();
        await tester.tap(find.byKey(const ValueKey('conflict-apply')));
        await _settle(tester);
        expect(result, {'parts/Shaft.didsa': choice});
      }
    });

    testWidgets('Keep mine is not offered when a file or folder is in the way', (tester) async {
      await show(tester, [conflicts.last], (_) {});
      final chip = tester.widget<ChoiceChip>(find.byKey(const ValueKey('conflict-keepMine-x.didsa')));
      expect(chip.onSelected, isNull);
    });

    testWidgets('Decide later returns null: nothing is chosen', (tester) async {
      var called = false;
      Map<String, ConflictChoice>? result = {};
      await show(tester, conflicts, (r) {
        called = true;
        result = r;
      });
      await tester.tap(find.byKey(const ValueKey('conflict-later')));
      await _settle(tester);
      expect(called, isTrue);
      expect(result, isNull);
    });
  });

  group('changed on disk (local folders, S0-8)', () {
    testWidgets('offers Overwrite, Skip these files and Cancel, and returns the choice', (tester) async {
      for (final entry in {
        'changed-overwrite': ChangedOnDiskChoice.overwrite,
        'changed-skip': ChangedOnDiskChoice.skipChanged,
        'changed-cancel': ChangedOnDiskChoice.cancel,
      }.entries) {
        ChangedOnDiskChoice? result;
        await tester.pumpWidget(
          MaterialApp(
            home: Builder(
              builder: (context) => Scaffold(
                body: TextButton(onPressed: () async => result = await showChangedOnDiskDialog(context, ['a.didsa', 'parts/b.didsa']), child: const Text('go')),
              ),
            ),
          ),
        );
        await tester.tap(find.text('go'));
        await _settle(tester);
        expect(find.text('2 files changed on disk'), findsOneWidget);
        expect(find.text('• parts/b.didsa'), findsOneWidget);
        await tester.tap(find.byKey(ValueKey(entry.key)));
        await _settle(tester);
        expect(result, entry.value);
      }
    });
  });

  group('the sync chip', () {
    Future<void> pumpChip(WidgetTester tester, RemoteStorageService remote, ServerProjectRoot root) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: Center(child: ServerSyncChip(remote: remote, root: root, onSyncNow: () async {}, onResolve: () async {}))),
        ),
      );
      await _settle(tester);
    }

    testWidgets('Synced, N to send (offline), Clash, in turn', (tester) async {
      final store = FakeProjectStore();
      store.write('Gearbox', 'a.didsa', _file('p-a'));
      final remote = _service(store);
      final root = remote.rootFor('Gearbox');
      remote.beginSession(root);
      await remote.readFile((await remote.resolve(root, 'a.didsa'))!);

      await pumpChip(tester, remote, root);
      expect(find.text('Synced'), findsOneWidget);

      store.offline = true;
      await remote.writeFile(root, 'a.didsa', _file('p-a-2'));
      await _settle(tester);
      expect(find.text('1 to send · offline'), findsOneWidget);

      store.offline = false;
      store.write('Gearbox', 'a.didsa', _file('p-a-3'), device: 'Quest 3');
      await remote.sync(root);
      await _settle(tester);
      expect(find.text('Clash'), findsOneWidget);
    });

    testWidgets('tapping it opens the sheet with Resolve for a clash and Sync now', (tester) async {
      final store = FakeProjectStore();
      store.write('Gearbox', 'a.didsa', _file('p-a'));
      final remote = _service(store);
      final root = remote.rootFor('Gearbox');
      remote.beginSession(root);
      await remote.readFile((await remote.resolve(root, 'a.didsa'))!);
      store.write('Gearbox', 'a.didsa', _file('p-a-3'), device: 'Quest 3');
      await remote.writeFile(root, 'a.didsa', _file('p-a-2')).then<void>((_) {}, onError: (Object _) {});

      await pumpChip(tester, remote, root);
      expect(find.text('Clash'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('server-sync-chip')));
      await _settle(tester);
      expect(find.byKey(const ValueKey('server-sync-sheet')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-sheet-resolve')), findsOneWidget);
      expect(find.byKey(const ValueKey('sync-sheet-sync')), findsOneWidget);
    });

    test('describe: a clash wins over a queue, a queue over offline, offline over synced', () {
      const scheme = ColorScheme.light();
      expect(ServerSyncChip.describe(const SyncSummary(online: false, toSend: 2, clash: 1), scheme).label, 'Clash');
      expect(ServerSyncChip.describe(const SyncSummary(online: true, toSend: 2), scheme).label, '2 to send');
      expect(ServerSyncChip.describe(const SyncSummary(online: false), scheme).label, 'Offline');
      expect(ServerSyncChip.describe(const SyncSummary(online: true), scheme).label, 'Synced');
      expect(ServerSyncChip.describe(const SyncSummary(clash: 3), scheme).label, '3 clashes');
    });
  });
}
