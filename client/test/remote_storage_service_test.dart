// RemoteStorageService against a fake project store (`test/support/fake_project_store.dart`): reads, versioned writes, the stale-write
// path, the offline queue and the sync on reconnect, the three conflict choices, Save All as one commit, store statuses, and the
// moved-files lookup through the store's part index. Plain `test()`: no widget binding, no real network.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/storage/desktop_storage_service.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/file_handle.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/server/remote_storage_service.dart';
import 'package:didsa_cad_client/storage/server/store_client.dart';
import 'package:didsa_cad_client/storage/server/sync_conflicts.dart';
import 'package:didsa_cad_client/storage/server/sync_state.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

import 'support/fake_project_store.dart';

Map<String, dynamic> nativeFile(String partId, {String? name, List<Map<String, dynamic>> occurrences = const [], int marker = 0}) => {
      'schema_version': 1,
      'document': {
        'id': 'doc-$partId',
        'root_part_id': partId,
        'parts': [
          {'id': partId, 'name': name ?? partId, 'features': [], 'occurrences': occurrences, 'mates': [], 'marker': marker},
        ],
      },
      'sketches': [],
    };

Uint8List encode(Map<String, dynamic> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> decode(List<int> bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

Map<String, dynamic> occurrence(String id, String ref, {String? refPartId}) => {
      'id': id,
      'external_ref': ref,
      'name_override': null,
      'transform': {'translation': [0.0, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
      'suppressed': false,
      'hidden': false,
      if (refPartId != null) 'ref_part_id': refPartId,
    };

String rootPartId(List<int> bytes) => (decode(bytes)['document'] as Map)['root_part_id'] as String;

void main() {
  late Directory temp;
  late FakeProjectStore store;
  late RemoteStorageService remote;
  late ServerProjectRoot root;
  late DateTime now;
  var deviceName = 'Desktop';

  RemoteStorageService makeService({int? tunnelLimit}) => RemoteStorageService(
        settings: () => StoreSettings(url: 'https://store.test', apiKey: 'store-key', deviceName: deviceName),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/sync')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/cache')),
        clock: () => now,
        treeTtl: Duration.zero,
        tunnelLimitBytes: tunnelLimit ?? kTunnelLimitBytes,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('didsa_remote_storage_test_');
    now = DateTime.utc(2026, 11, 13, 12);
    deviceName = 'Desktop';
    store = FakeProjectStore(clock: () => now);
    store.createProject('Gearbox');
    remote = makeService();
    root = remote.rootFor('Gearbox');
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Uint8List> read(String path) async => remote.readFile((await remote.resolve(root, path))!);

  group('reads', () {
    test('resolve, read and list a server project', () async {
      store.writeJson('Gearbox', 'Gearbox.didsa', nativeFile('p-asm'));
      store.writeJson('Gearbox', 'parts/Shaft.didsa', nativeFile('p-shaft'));
      remote.beginSession(root);

      final handle = await remote.resolve(root, 'parts/Shaft.didsa');
      expect(handle, isA<ServerFileHandle>());
      expect((handle as ServerFileHandle).version, 1);
      expect(rootPartId(await remote.readFile(handle)), 'p-shaft');
      expect(await remote.resolve(root, 'nope.didsa'), isNull);
      expect(await remote.exists(handle), isTrue);
      expect(await remote.listFiles(root), unorderedEquals(['Gearbox.didsa', 'parts/Shaft.didsa']));
      expect(await remote.listFiles(root, extensionFilter: '.didsa'), hasLength(2));
      expect(await remote.lastModified(handle), isNotNull);
    });

    test('a missing file is a StorageException', () async {
      await expectLater(remote.readFile(ServerFileHandle(root: root, relativePath: 'gone.didsa')), throwsA(isA<StorageException>()));
    });

    test('X-Device-Name is sent, the key is sent, and a wrong key is a clear StorageException (401)', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      await read('a.didsa');
      expect(store.devices.toSet(), {'Desktop'});

      final wrong = RemoteStorageService(
        settings: () => const StoreSettings(url: 'https://store.test', apiKey: 'wrong', deviceName: 'Desktop'),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/sync2')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/cache2')),
      );
      await expectLater(
        wrong.listProjects(),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('401'))),
      );
    });

    test('a device name with characters a header cannot carry is still sent', () async {
      deviceName = 'Quest 3 – Ünï';
      remote = makeService();
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      await read('a.didsa');
      expect(store.devices.toSet().single, isNot(contains('–')));
      expect(store.devices.toSet().single, startsWith('Quest 3'));
    });
  });

  group('versioned writes', () {
    test('a write replaces the version that was read, and the store records the device', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');

      final handle = await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1)));

      expect((handle as ServerFileHandle).version, 2);
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 1);
      expect(store.deviceOf('Gearbox', 'a.didsa'), 'Desktop');
      expect(remote.statusOf(root).value.allSynced, isTrue);
    });

    test('a new file is created (If-None-Match), and a second write replaces the version the first one made', () async {
      remote.beginSession(root);
      await remote.writeFile(root, 'new.didsa', encode(nativeFile('p-new')));
      expect(store.versionOf('Gearbox', 'new.didsa'), 1);
      await remote.writeFile(root, 'new.didsa', encode(nativeFile('p-new', marker: 1)));
      expect(store.versionOf('Gearbox', 'new.didsa'), 2);
    });

    test('a write of the same bytes sends nothing', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      final bytes = await read('a.didsa');
      final before = store.count('PUT');
      await remote.writeFile(root, 'a.didsa', bytes);
      expect(store.count('PUT'), before);
    });

    test('baseVersion names the version replaced; a wrong one is refused as stale', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 1)); // now v2
      remote.beginSession(root);
      await expectLater(
        remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 9)), baseVersion: 1),
        throwsA(isA<SyncConflictException>()),
      );
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.keepMine});
      await remote.sync(root);
      expect(store.versionOf('Gearbox', 'a.didsa'), 3);
    });

    test('a re-read in the same session does not move the base: a later save of the stale copy is a clash', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa'); // the session loads v1
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 5)); // someone saves v2
      await read('a.didsa'); // something re-reads it (Add Component, a second compose)
      await expectLater(
        remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1))),
        throwsA(isA<SyncConflictException>()),
      );
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 5);
    });
  });

  group('the stale single write (412)', () {
    test('is refused, writes nothing, says who changed it, and keeps my bytes queued as a clash', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      now = DateTime.utc(2026, 11, 13, 14, 5);
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 7), device: 'Quest 3');

      SyncConflictException? caught;
      try {
        await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1)));
      } on SyncConflictException catch (e) {
        caught = e;
      }

      expect(caught, isNotNull);
      expect(caught, isA<StorageException>());
      final conflict = caught!.conflicts.single;
      expect(conflict.path, 'a.didsa');
      expect(conflict.clash.modifiedBy, 'Quest 3');
      expect(conflict.clash.currentVersion, 2);
      expect(conflict.describe(), contains('Quest 3'));
      expect(conflict.describe(), contains('2026-11-13'));
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 7);
      final status = remote.statusOf(root).value;
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.clash, 1);
      expect(status.allSynced, isFalse);
      // My bytes are still readable (the queued save).
      expect(decode(await read('a.didsa'))['document']['parts'][0]['marker'], 1);
    });

    test('creating a file that another device created first is a clash too ("exists")', () async {
      remote.beginSession(root);
      store.writeJson('Gearbox', 'x.didsa', nativeFile('p-x'), device: 'Quest 3');
      final error = await remote.writeFile(root, 'x.didsa', encode(nativeFile('p-x2'))).then<Object?>((_) => null, onError: (Object e) => e);
      expect(error, isA<SyncConflictException>());
      expect((error as SyncConflictException).conflicts.single.clash.reason, 'exists');
    });
  });

  group('store statuses', () {
    test('413 is a clear message and the save is not lost (it stays queued, with a problem noted)', () async {
      store.maxFileBytes = 10;
      remote.beginSession(root);
      await expectLater(
        remote.writeFile(root, 'big.didsa', Uint8List(50)),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', allOf(contains('big.didsa'), contains('too large')))),
      );
      expect(store.livePaths('Gearbox'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 1);
      expect(remote.statusOf(root).value.problems, contains('big.didsa'));
    });

    test('a file over the tunnel limit that fails with the store answering explains the limit, no chunking', () async {
      remote = makeService(tunnelLimit: 10);
      remote.beginSession(root);
      // The connection to the upload fails (a tunnel resetting it) while the store still answers /health.
      store.dropNextWrite = true;
      await expectLater(
        remote.writeFile(root, 'huge.step', Uint8List(50)),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', allOf(contains('Cloudflare'), contains('100 MB'), contains('chunked')))),
      );
    });

    test('400 (a refused name) surfaces the store message and queues nothing', () async {
      store.forcedAnswers.add((status: 400, body: jsonEncode({'error': 'bad_path', 'detail': 'a path may not contain a colon'})));
      remote.beginSession(root);
      await expectLater(
        remote.writeFile(root, 'a:b.didsa', encode(nativeFile('p'))),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('colon'))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 0);
    });

    test('428 is reported as a client bug (the app always sends a precondition)', () async {
      store.forcedAnswers.add((status: 428, body: jsonEncode({'error': 'precondition_required', 'detail': 'send If-Match'})));
      remote.beginSession(root);
      await expectLater(
        remote.writeFile(root, 'a.didsa', encode(nativeFile('p'))),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', allOf(contains('428'), contains('bug')))),
      );
    });

    test('401 on a write keeps the save queued and names the key', () async {
      store.forcedAnswers.add((status: 401, body: jsonEncode({'error': 'unauthorized', 'detail': 'bad key'})));
      remote.beginSession(root);
      await expectLater(
        remote.writeFile(root, 'a.didsa', encode(nativeFile('p'))),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', allOf(contains('401'), contains('key')))),
      );
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 1);
    });

    test('every write the client sends carries a precondition (a fake that answers 428 never does)', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1)));
      await remote.writeFile(root, 'b.didsa', encode(nativeFile('p-b')));
      await remote.commit(root, [FileChange(path: 'c.didsa', bytes: encode(nativeFile('p-c')))]);
      // The fake answers 428 to a PUT with neither header; none of these threw.
      expect(store.versionOf('Gearbox', 'b.didsa'), 1);
    });
  });

  group('offline', () {
    test('open from the local copy: reads, resolve and list answer from what this device kept', () async {
      store.writeJson('Gearbox', 'Gearbox.didsa', nativeFile('p-asm'));
      store.writeJson('Gearbox', 'parts/Shaft.didsa', nativeFile('p-shaft'));
      remote.beginSession(root);
      await read('Gearbox.didsa');
      await read('parts/Shaft.didsa');

      store.offline = true;
      remote = makeService(); // a fresh process: nothing in memory
      remote.beginSession(root);

      expect(rootPartId(await read('parts/Shaft.didsa')), 'p-shaft');
      expect(await remote.listFiles(root), unorderedEquals(['Gearbox.didsa', 'parts/Shaft.didsa']));
      expect(remote.statusOf(root).value.online, isFalse);
    });

    test('a file never opened is not available offline, and says so', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await remote.listFiles(root);
      store.offline = true;
      await expectLater(
        remote.readFile(ServerFileHandle(root: root, relativePath: 'a.didsa')),
        throwsA(isA<StoreOfflineException>()),
      );
    });

    test('a save while offline goes to the queue, is readable, and is not lost across a restart', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      store.offline = true;

      final handle = await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 3)));

      expect(handle.relativePath, 'a.didsa');
      expect(store.versionOf('Gearbox', 'a.didsa'), 1);
      await Future<void>.delayed(Duration.zero);
      final status = remote.statusOf(root).value;
      expect(status.toSend, 1);
      expect(status.online, isFalse);
      expect(decode(await read('a.didsa'))['document']['parts'][0]['marker'], 3);

      remote = makeService(); // the app was closed and reopened
      remote.beginSession(root);
      expect(decode(await read('a.didsa'))['document']['parts'][0]['marker'], 3);
      expect((await remote.conflicts(root)), isEmpty);
      expect(await remote.fileState(root, 'a.didsa'), SyncFileState.toSend);
    });

    test('sync on reconnect asks the change feed first, then sends the queue as one commit', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      store.writeJson('Gearbox', 'b.didsa', nativeFile('p-b'));
      remote.beginSession(root);
      await read('a.didsa');
      await read('b.didsa');
      await remote.sync(root); // saves the cursor
      store.offline = true;
      await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1)));
      await remote.writeFile(root, 'b.didsa', encode(nativeFile('p-b', marker: 1)));
      expect((await remote.sync(root)).reachable, isFalse);

      store.offline = false;
      store.requests.clear();
      final report = await remote.sync(root);

      expect(report.reachable, isTrue);
      expect(report.sent, unorderedEquals(['a.didsa', 'b.didsa']));
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      expect(store.versionOf('Gearbox', 'b.didsa'), 2);
      final changesAt = store.requests.indexWhere((r) => r.contains('/changes'));
      final commitAt = store.requests.indexWhere((r) => r.contains('/commit'));
      expect(changesAt, greaterThanOrEqualTo(0));
      expect(commitAt, greaterThan(changesAt));
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.count('PUT'), 0);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.allSynced, isTrue);
      expect(remote.statusOf(root).value.lastSyncedAt, isNotNull);
    });

    test('sync with nothing queued and nothing changed asks only the feed (no tree, no commit)', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      await remote.sync(root);
      store.requests.clear();
      await remote.sync(root);
      expect(store.requests, ['GET /projects/Gearbox/changes']);
    });

    test('a cached copy of a file another device changed is brought level by sync', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      await remote.sync(root);
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 8));

      remote = makeService(); // a later launch: nothing touched yet
      final report = await remote.sync(root);
      expect(report.refreshed, ['a.didsa']);

      store.offline = true;
      expect(decode(await read('a.didsa'))['document']['parts'][0]['marker'], 8);
    });

    test('a queued save that the feed shows is now stale is flagged as a clash without sending anything', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      await remote.sync(root);
      store.offline = true;
      await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1)));
      store.offline = false;
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 5), device: 'Quest 3');
      store.requests.clear();

      final report = await remote.sync(root);

      expect(report.conflicts.single.path, 'a.didsa');
      expect(report.conflicts.single.clash.modifiedBy, 'Quest 3');
      expect(store.count('POST'), 0);
      expect(store.count('PUT'), 0);
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      expect(await remote.fileState(root, 'a.didsa'), SyncFileState.clash);
    });
  });

  group('the three conflict choices', () {
    Future<void> clashOnA() async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      now = DateTime.utc(2026, 11, 13, 14, 5);
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a', marker: 7), device: 'Quest 3');
      await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1))).then<void>((_) {}, onError: (Object _) {});
    }

    test('Keep mine writes mine as the next version over theirs (theirs stays in the history)', () async {
      await clashOnA();

      await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.keepMine});
      final report = await remote.sync(root);

      expect(report.sent, ['a.didsa']);
      expect(store.versionOf('Gearbox', 'a.didsa'), 3);
      expect(store.historyLength('Gearbox', 'a.didsa'), 3);
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 1);
      expect(await remote.fileState(root, 'a.didsa'), SyncFileState.synced);
    });

    test('Take theirs drops mine, loads theirs, and keeps my bytes as a local copy until the next successful sync', () async {
      await clashOnA();

      final result = await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.takeTheirs});
      expect(result.reload, isTrue);
      expect(store.versionOf('Gearbox', 'a.didsa'), 2);
      expect(decode(await read('a.didsa'))['document']['parts'][0]['marker'], 7);
      expect(await remote.fileState(root, 'a.didsa'), SyncFileState.synced);
      expect(await remote.keptCopies(root), ['a.didsa']);
      expect(decode((await remote.keptCopy(root, 'a.didsa'))!)['document']['parts'][0]['marker'], 1);

      final afterResolve = await remote.sync(root); // the resolution's own sync
      expect(afterResolve.sent, isEmpty);
      expect(await remote.keptCopies(root), ['a.didsa'], reason: 'the copy survives the sync that finishes the resolution');
      await remote.sync(root); // the next successful sync
      expect(await remote.keptCopies(root), isEmpty);
      expect(store.versionOf('Gearbox', 'a.didsa'), 2, reason: 'theirs was never overwritten');
    });

    test('a kept copy can be put back as a file of its own (new Part id)', () async {
      await clashOnA();
      await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.takeTheirs});
      final copyPath = await remote.restoreKeptCopyAsFile(root, 'a.didsa');
      await remote.sync(root);
      expect(copyPath, 'a (Desktop, 2026-11-13).didsa');
      expect(rootPartId(store.bytesOf('Gearbox', copyPath)!), isNot('p-a'));
      expect(await remote.keptCopies(root), isEmpty);
    });

    test('Save mine as a copy writes "<name> (<device>, <date>).didsa" beside theirs, with a NEW Part id', () async {
      await clashOnA();

      final result = await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.saveCopy});
      await remote.sync(root);

      expect(result.copies, {'a.didsa': 'a (Desktop, 2026-11-13).didsa'});
      expect(store.livePaths('Gearbox'), ['a (Desktop, 2026-11-13).didsa', 'a.didsa']);
      // Theirs is untouched at the original path; mine is in the copy.
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 7);
      final copy = decode(store.bytesOf('Gearbox', 'a (Desktop, 2026-11-13).didsa')!);
      expect(copy['document']['parts'][0]['marker'], 1);
      final newId = rootPartId(store.bytesOf('Gearbox', 'a (Desktop, 2026-11-13).didsa')!);
      expect(newId, isNot('p-a'));
      expect(copy['document']['parts'][0]['id'], newId, reason: 'the whole file follows the new id');
      expect(copy['document']['id'], isNot('doc-p-a'));
      // The two files never share an id: the moved-files rule would otherwise ask every time.
      expect(rootPartId(store.bytesOf('Gearbox', 'a.didsa')!), 'p-a');
    });

    test('a copy whose name is taken gets a number', () {
      final taken = {'a (Desktop, 2026-11-13).didsa'};
      expect(conflictCopyPath('a.didsa', 'Desktop', DateTime(2026, 11, 13), taken.contains), 'a (Desktop, 2026-11-13) 2.didsa');
      expect(conflictCopyPath('parts/Shaft.DIDSAprt', 'Quest/3', DateTime(2026, 1, 2), (_) => false), 'parts/Shaft (Quest3, 2026-01-02).didsa');
    });

    test('Keep mine on a file another device deleted writes it at the old path again', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      store.delete('Gearbox', 'a.didsa', device: 'Quest 3');
      final error = await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1))).then<Object?>((_) => null, onError: (Object e) => e);
      final conflict = (error as SyncConflictException).conflicts.single;
      expect(conflict.clash.deleted, isTrue);
      expect(conflict.describe(), startsWith('Deleted by Quest 3'));

      await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.keepMine});
      await remote.sync(root);

      expect(store.livePaths('Gearbox'), ['a.didsa']);
      expect(decode(store.bytesOf('Gearbox', 'a.didsa')!)['document']['parts'][0]['marker'], 1);
    });

    test('Take theirs on a deleted file removes it from the local copy', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      remote.beginSession(root);
      await read('a.didsa');
      store.delete('Gearbox', 'a.didsa');
      await remote.writeFile(root, 'a.didsa', encode(nativeFile('p-a', marker: 1))).then<void>((_) {}, onError: (Object _) {});

      await remote.resolveConflicts(root, {'a.didsa': ConflictChoice.takeTheirs});

      expect(await remote.resolve(root, 'a.didsa'), isNull);
      expect(store.livePaths('Gearbox'), isEmpty);
    });
  });

  group('Save All is one commit', () {
    Future<void> openTwo() async {
      store.writeJson('Gearbox', 'Gearbox.didsa', nativeFile('p-asm'));
      store.writeJson('Gearbox', 'parts/Shaft.didsa', nativeFile('p-shaft'));
      store.writeJson('Gearbox', 'parts/Gear.didsa', nativeFile('p-gear'));
      remote.beginSession(root);
      for (final p in ['Gearbox.didsa', 'parts/Shaft.didsa', 'parts/Gear.didsa']) {
        await read(p);
      }
    }

    List<FileChange> changes(int marker) => [
          for (final p in ['Gearbox.didsa', 'parts/Shaft.didsa', 'parts/Gear.didsa'])
            FileChange(path: p, bytes: encode(nativeFile(p == 'Gearbox.didsa' ? 'p-asm' : (p.contains('Shaft') ? 'p-shaft' : 'p-gear'), marker: marker))),
        ];

    test('every file lands in a single commit request', () async {
      await openTwo();
      store.requests.clear();

      final outcome = await remote.commit(root, changes(1), message: 'Save All');

      expect(outcome.sent, hasLength(3));
      expect(outcome.queued, isEmpty);
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.count('POST /projects/Gearbox/uploads'), 3);
      expect(store.count('PUT'), 0);
      for (final p in ['Gearbox.didsa', 'parts/Shaft.didsa', 'parts/Gear.didsa']) {
        expect(store.versionOf('Gearbox', p), 2);
      }
      expect(remote.supportsCommit(root), isTrue);
      expect(remote.supportsCommit(const DesktopProjectRoot('/x')), isFalse);
    });

    test('files that did not change are not sent', () async {
      await openTwo();
      final same = [
        for (final p in ['Gearbox.didsa', 'parts/Shaft.didsa', 'parts/Gear.didsa']) FileChange(path: p, bytes: (await read(p))),
      ];
      store.requests.clear();
      await remote.commit(root, same);
      expect(store.requests, isEmpty);
    });

    test('a 409 writes NOTHING (not even the files that did not clash), lists every clash, and the retry after resolving lands', () async {
      await openTwo();
      store.writeJson('Gearbox', 'parts/Shaft.didsa', nativeFile('p-shaft', marker: 4), device: 'Quest 3');
      store.writeJson('Gearbox', 'parts/Gear.didsa', nativeFile('p-gear', marker: 4), device: 'Phone');
      final before = {for (final p in store.livePaths('Gearbox')) p: store.versionOf('Gearbox', p)};

      SyncConflictException? clash;
      try {
        await remote.commit(root, changes(1));
      } on SyncConflictException catch (e) {
        clash = e;
      }

      expect(clash, isNotNull);
      expect(clash!.conflicts.map((c) => c.path), unorderedEquals(['parts/Shaft.didsa', 'parts/Gear.didsa']));
      expect({for (final c in clash.conflicts) c.path: c.clash.modifiedBy}, {'parts/Shaft.didsa': 'Quest 3', 'parts/Gear.didsa': 'Phone'});
      expect({for (final p in store.livePaths('Gearbox')) p: store.versionOf('Gearbox', p)}, before, reason: 'nothing was written');
      expect(decode(store.bytesOf('Gearbox', 'Gearbox.didsa')!)['document']['parts'][0]['marker'], 0);
      // All three saves wait in the queue: two as clashes, one to send.
      expect(await remote.fileState(root, 'Gearbox.didsa'), SyncFileState.toSend);
      expect(await remote.fileState(root, 'parts/Shaft.didsa'), SyncFileState.clash);
      expect((await remote.conflicts(root)).length, 2);

      // The user chooses per file; then the commit is sent again.
      await remote.resolveConflicts(root, {'parts/Shaft.didsa': ConflictChoice.keepMine, 'parts/Gear.didsa': ConflictChoice.takeTheirs});
      store.requests.clear();
      final report = await remote.sync(root);

      expect(report.conflicts, isEmpty);
      expect(report.sent, ['Gearbox.didsa', 'parts/Shaft.didsa']);
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.versionOf('Gearbox', 'Gearbox.didsa'), 2);
      expect(store.versionOf('Gearbox', 'parts/Shaft.didsa'), 3);
      expect(store.versionOf('Gearbox', 'parts/Gear.didsa'), 2, reason: 'Take theirs: theirs stays');
      expect(decode(store.bytesOf('Gearbox', 'parts/Shaft.didsa')!)['document']['parts'][0]['marker'], 1);
    });

    test('offline: the whole Save All is queued (nothing lost) and sent as one commit on reconnect', () async {
      await openTwo();
      store.offline = true;

      final outcome = await remote.commit(root, changes(2));

      expect(outcome.sent, isEmpty);
      expect(outcome.queued, hasLength(3));
      store.offline = false;
      store.requests.clear();
      final report = await remote.sync(root);
      expect(report.sent, hasLength(3));
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.versionOf('Gearbox', 'Gearbox.didsa'), 2);
    });

    test('an upload that expired (the store keeps them an hour) is uploaded again, once, and the commit lands', () async {
      await openTwo();
      store.forcedAnswers
        ..add((status: 201, body: jsonEncode({'upload_id': 'gone1'})))
        ..add((status: 201, body: jsonEncode({'upload_id': 'gone2'})))
        ..add((status: 201, body: jsonEncode({'upload_id': 'gone3'})));
      final outcome = await remote.commit(root, changes(3));
      expect(outcome.sent, hasLength(3));
      expect(store.versionOf('Gearbox', 'Gearbox.didsa'), 2);
    });
  });

  group('rename', () {
    test('renames a file through a commit move and keeps the local copy under the new name', () async {
      store.writeJson('Gearbox', 'parts/Shaft.didsa', nativeFile('p-shaft'));
      remote.beginSession(root);
      await read('parts/Shaft.didsa');

      final handle = await remote.renameFile(root, 'parts/Shaft.didsa', 'Shaft-v2.didsa');

      expect(handle.relativePath, 'parts/Shaft-v2.didsa');
      expect(store.livePaths('Gearbox'), ['parts/Shaft-v2.didsa']);
      expect(rootPartId(await read('parts/Shaft-v2.didsa')), 'p-shaft');
    });

    test('renaming over an existing file, or while offline, is a clear error', () async {
      store.writeJson('Gearbox', 'a.didsa', nativeFile('p-a'));
      store.writeJson('Gearbox', 'b.didsa', nativeFile('p-b'));
      remote.beginSession(root);
      await expectLater(remote.renameFile(root, 'a.didsa', 'b.didsa'), throwsA(isA<StorageException>()));
      store.offline = true;
      await expectLater(remote.renameFile(root, 'a.didsa', 'c.didsa'), throwsA(isA<StoreOfflineException>()));
    });
  });

  group('the moved-files rule against the store', () {
    test('a moved file is found by Part id through the part index, without reading every file', () async {
      store.writeJson('Gearbox', 'Gearbox.didsa', nativeFile('p-asm', occurrences: [occurrence('o1', 'parts/Shaft.didsa', refPartId: 'p-shaft')]));
      store.writeJson('Gearbox', 'archive/old/Shaft.didsa', nativeFile('p-shaft')); // moved here
      for (var i = 0; i < 12; i++) {
        store.writeJson('Gearbox', 'library/Part$i.didsa', nativeFile('p-lib-$i'));
      }
      remote.beginSession(root);
      final composer = AssemblyGraphComposer(
        storageService: remote,
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/composer-cache')),
      );
      store.requests.clear();

      final composed = await composer.compose(root, 'Gearbox.didsa');

      final report = composed.references.single;
      expect(report.outcome, ReferenceOutcome.movedById);
      expect(report.foundPath, 'archive/old/Shaft.didsa');
      expect(composed.relativePathByPartId.values, containsAll(['Gearbox.didsa', 'archive/old/Shaft.didsa']));
      expect(store.count('GET /projects/Gearbox/parts/p-shaft'), 1);
      // Only the two files that matter were read: the root and the one found by id.
      final fileReads = store.requests.where((r) => r.startsWith('GET /projects/Gearbox/files/')).toList();
      expect(fileReads.toSet(), {'GET /projects/Gearbox/files/Gearbox.didsa', 'GET /projects/Gearbox/files/archive/old/Shaft.didsa'});
    });

    test('a file saved here but not sent yet is found by its own id (the store does not have it)', () async {
      store.writeJson('Gearbox', 'Gearbox.didsa', nativeFile('p-asm', occurrences: [occurrence('o1', 'parts/Shaft.didsa', refPartId: 'p-shaft')]));
      remote.beginSession(root);
      store.offline = true;
      await remote.writeFile(root, 'elsewhere/Shaft.didsa', encode(nativeFile('p-shaft')));
      expect(await remote.pathsWithPartId(root, 'p-shaft'), ['elsewhere/Shaft.didsa']);
      expect(await remote.pathsWithPartId(root, 'nobody'), isEmpty);
      expect(await remote.pathsWithPartId(const DesktopProjectRoot('/x'), 'p-shaft'), isNull);
    });

    test('an unknown id is an empty answer (the store answers 200 with [])', () async {
      remote.beginSession(root);
      expect(await remote.pathsWithPartId(root, 'unknown'), isEmpty);
    });
  });

  group('copy this project to the server', () {
    test('copies every file of a local folder into a new server project in one commit; hidden files stay out', () async {
      final folder = Directory('${temp.path}/local')..createSync();
      File('${folder.path}/Gearbox.didsa').writeAsBytesSync(encode(nativeFile('p-asm')));
      Directory('${folder.path}/parts').createSync();
      File('${folder.path}/parts/Shaft.didsa').writeAsBytesSync(encode(nativeFile('p-shaft')));
      File('${folder.path}/notes.txt').writeAsStringSync('hello');
      Directory('${folder.path}/.git').createSync();
      File('${folder.path}/.git/config').writeAsStringSync('x');
      final local = DesktopStorageService();
      final localRoot = DesktopProjectRoot(folder.path);
      final progress = <int>[];

      final created = await remote.copyProjectToServer(local, localRoot, 'Copied', onProgress: (done, total) => progress.add(done));

      expect(created, remote.rootFor('Copied'));
      expect(store.livePaths('Copied'), ['Gearbox.didsa', 'notes.txt', 'parts/Shaft.didsa']);
      expect(rootPartId(store.bytesOf('Copied', 'parts/Shaft.didsa')!), 'p-shaft');
      expect(store.count('POST /projects/Copied/commit'), 1);
      expect(progress, isNotEmpty);
    });

    test('a project name that is taken is a clear error and nothing is copied', () async {
      final folder = Directory('${temp.path}/local')..createSync();
      File('${folder.path}/a.didsa').writeAsBytesSync(encode(nativeFile('p-a')));
      await expectLater(
        remote.copyProjectToServer(DesktopStorageService(), DesktopProjectRoot(folder.path), 'Gearbox'),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('already exists'))),
      );
      expect(store.livePaths('Gearbox'), isEmpty);
    });
  });

  group('settings and projects', () {
    test('listProjects and createProject, and an unreachable store is StoreOfflineException', () async {
      expect((await remote.listProjects()).map((p) => p.name), ['Gearbox']);
      final created = await remote.createProject('Second');
      expect(created.project, 'Second');
      expect((await remote.listProjects()).map((p) => p.name), unorderedEquals(['Gearbox', 'Second']));
      store.offline = true;
      await expectLater(remote.listProjects(), throwsA(isA<StoreOfflineException>()));
    });

    test('checkConnection says what is wrong', () async {
      expect(await remote.checkConnection(), isNull);
      expect(await remote.checkConnection(key: 'nope'), contains('refused the key'));
      store.offline = true;
      expect(await remote.checkConnection(), contains('could not be reached'));
    });

    test('a root on another store than the settings point at is refused, not sent the wrong key', () async {
      final other = ServerProjectRoot(serverUrl: 'https://other.test', project: 'Gearbox');
      await expectLater(remote.listFiles(other), throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('other.test'))));
    });

    test('an unconfigured store asks for the settings', () async {
      final unset = RemoteStorageService(
        settings: () => const StoreSettings(url: '', apiKey: '', deviceName: 'x'),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/sync4')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/cache4')),
      );
      expect(unset.isConfigured, isFalse);
      await expectLater(unset.listProjects(), throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('server settings'))));
    });
  });
}
