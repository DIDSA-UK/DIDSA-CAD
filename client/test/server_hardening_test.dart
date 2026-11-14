// S4 (docs/mates-storage-sessions-plan-2026-11-12.md, "S4. Hardening"): server projects when the network or the store misbehaves, against the fake
// store (`test/support/fake_project_store.dart`), which can be switched off and on, dropped after N requests, or lose a reply AFTER applying the
// request: chunked upload past the tunnel's request limit, an upload cut off and resumed (after the store was off and after the app was closed),
// a lost reply to a chunk, a commit that landed with its reply lost, an expired or damaged upload, a store without chunk support, and two devices
// offline on one file. `test/live/server_store_live_test.dart` runs the chunking against the real store.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/server/remote_storage_service.dart';
import 'package:didsa_cad_client/storage/server/store_client.dart';
import 'package:didsa_cad_client/storage/server/sync_conflicts.dart';
import 'package:didsa_cad_client/storage/server/sync_state.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

import 'support/fake_project_store.dart';

Uint8List bytesOf(String tag, int length) => Uint8List.fromList(utf8.encode(tag * length).sublist(0, length));

void main() {
  late Directory temp;
  late FakeProjectStore store;
  late RemoteStorageService remote;
  late ServerProjectRoot root;
  late DateTime now;

  RemoteStorageService service({String device = 'Quest 3', String folder = 'a'}) => RemoteStorageService(
        settings: () => StoreSettings(url: 'https://store.test', apiKey: 'store-key', deviceName: device),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/$folder/sync')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/$folder/cache')),
        clock: () => now,
        treeTtl: Duration.zero,
        chunkThresholdBytes: 20, // (the real values: 90 MB and 32 MB)
        chunkBytes: 10,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('didsa_hardening_test_');
    now = DateTime.utc(2026, 11, 14, 12);
    store = FakeProjectStore(clock: () => now);
    store.createProject('Gearbox');
    remote = service();
    root = remote.rootFor('Gearbox');
    remote.beginSession(root);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  group('chunked upload', () {
    test('a single save of a big file goes up as chunks and lands as one version, never as a PUT of the whole file', () async {
      final big = bytesOf('a', 55);
      await remote.writeFile(root, 'Big.didsa', big);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), big);
      expect(store.chunksReceived, 6);
      expect(store.versionOf('Gearbox', 'Big.didsa'), 1);
      expect(store.count('PUT /projects/Gearbox/files'), 0);
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      // an edit replaces the version it was based on
      await remote.writeFile(root, 'Big.didsa', bytesOf('b', 55));
      expect(store.versionOf('Gearbox', 'Big.didsa'), 2);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('b', 55));
    });

    test('Save All with a big file and a small one is ONE commit; the small one is one request', () async {
      await remote.commit(root, [FileChange(path: 'Big.didsa', bytes: bytesOf('c', 41)), FileChange(path: 'Small.didsa', bytes: bytesOf('s', 5))]);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('c', 41));
      expect(store.bytesOf('Gearbox', 'Small.didsa'), bytesOf('s', 5));
      expect(store.count('POST /projects/Gearbox/commit'), 1);
      expect(store.chunksReceived, 5);
      expect(store.count('POST /projects/Gearbox/uploads/sessions'), 1);
    });

    test('a file under the threshold is unchanged: one PUT, no chunks', () async {
      await remote.writeFile(root, 'Small.didsa', bytesOf('s', 8));
      expect(store.count('PUT /projects/Gearbox/files'), 1);
      expect(store.chunksReceived, 0);
    });

    test('a body a tunnel refuses (413, not the store\'s JSON) is retried in chunks, for a single save and for a commit', () async {
      remote = RemoteStorageService(
        settings: () => StoreSettings(url: 'https://store.test', apiKey: 'store-key', deviceName: 'Quest 3'),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/t/sync')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/t/cache')),
        clock: () => now,
        treeTtl: Duration.zero,
        chunkThresholdBytes: 1000,
        chunkBytes: 10,
      );
      root = remote.rootFor('Gearbox');
      remote.beginSession(root);
      store.tunnelCapBytes = 200; // (above the small JSON requests, below the file)
      await remote.writeFile(root, 'Mid.didsa', bytesOf('m', 500));
      expect(store.bytesOf('Gearbox', 'Mid.didsa'), bytesOf('m', 500));
      await remote.commit(root, [FileChange(path: 'Mid2.didsa', bytes: bytesOf('n', 500)), FileChange(path: 'Tiny.didsa', bytes: bytesOf('t', 3))]);
      expect(store.bytesOf('Gearbox', 'Mid2.didsa'), bytesOf('n', 500));
    });

    test('a store that predates chunks (no uploads.chunked): a clear message, the save kept', () async {
      store.chunked = false;
      await expectLater(
        remote.writeFile(root, 'Big.didsa', bytesOf('o', 55)),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', allOf(contains('too old'), contains('uploads.chunked')))),
      );
      expect(store.livePaths('Gearbox'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 1);
    });

    test('the store\'s own size limit is still reported with its message', () async {
      store.maxFileBytes = 40;
      await expectLater(
        remote.writeFile(root, 'Huge.didsa', bytesOf('h', 55)),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('too large'))),
      );
      expect(store.livePaths('Gearbox'), isEmpty);
    });
  });

  group('interrupted uploads and a store switched off and on', () {
    test('a store that dies mid-upload: the save is queued, then the upload RESUMES (no chunk twice, one version)', () async {
      remote.beginSession(root);
      store.dieAfter = 5; // health, session, then chunks 1-3 land, then the store is gone
      final handle = await remote.writeFile(root, 'Big.didsa', bytesOf('d', 55));
      expect(handle, isNotNull);
      final got = store.chunksReceived;
      expect(got, greaterThan(0));
      expect(got, lessThan(6));
      expect(store.livePaths('Gearbox'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 1);
      final sessionsBefore = store.count('POST /projects/Gearbox/uploads/sessions');
      store.restart();
      final report = await remote.sync(root);
      expect(report.sent, ['Big.didsa']);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('d', 55));
      expect(store.chunksReceived, 6);
      expect(store.count('POST /projects/Gearbox/uploads/sessions'), sessionsBefore);
      expect(store.versionOf('Gearbox', 'Big.didsa'), 1);
    });

    test('the app closed and opened again between the cut and the restart still resumes', () async {
      store.dieAfter = 4;
      await remote.writeFile(root, 'Big.didsa', bytesOf('e', 55));
      final half = store.chunksReceived;
      expect(half, greaterThan(0));
      expect(half, lessThan(6));
      // a new service over the same folders = the app started again
      final reopened = service();
      final root2 = reopened.rootFor('Gearbox');
      reopened.beginSession(root2);
      store.restart();
      await reopened.sync(root2);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('e', 55));
      expect(store.chunksReceived, 6);
    });

    test('a file edited between attempts starts a new upload and the store gets only the new bytes', () async {
      store.dieAfter = 4;
      await remote.writeFile(root, 'Big.didsa', bytesOf('f', 55));
      store.restart();
      await remote.writeFile(root, 'Big.didsa', bytesOf('g', 55));
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('g', 55));
      expect(store.versionOf('Gearbox', 'Big.didsa'), 1);
      expect(store.count('DELETE /projects/Gearbox/uploads/'), 1); // the abandoned session was cancelled
    });

    test('a lost reply to a chunk: the same chunk is sent again and the store says where it really is', () async {
      store.loseReplyFor.add('offset=10');
      await remote.writeFile(root, 'Big.didsa', bytesOf('l', 55));
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('l', 55));
      expect(store.chunksReceived, 6);
    });

    test('a commit that LANDED with its reply lost: the next sync recognises its own save (no clash, no second version)', () async {
      store.write('Gearbox', 'Doc.didsa', bytesOf('1', 30));
      remote.beginSession(root);
      await remote.readFile((await remote.resolve(root, 'Doc.didsa'))!);
      store.loseReplyFor.add('POST /projects/Gearbox/commit');
      await remote.commit(root, [FileChange(path: 'Doc.didsa', bytes: bytesOf('2', 30))]);
      expect(store.versionOf('Gearbox', 'Doc.didsa'), 2);
      final report = await remote.sync(root);
      expect(report.conflicts, isEmpty);
      expect(store.versionOf('Gearbox', 'Doc.didsa'), 2);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 0);
      expect(remote.statusOf(root).value.clash, 0);
    });

    test('an upload the store has forgotten is started again from the beginning, once', () async {
      store.dieAfter = 4;
      await remote.writeFile(root, 'Big.didsa', bytesOf('x', 55));
      store.restart();
      store.expireUploads();
      await remote.sync(root);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('x', 55));
    });

    test('a damaged upload (hash mismatch) writes nothing, keeps the save queued, and Sync sends it again', () async {
      store.failNextComplete = (status: 400, body: jsonEncode({'error': 'checksum_mismatch', 'detail': 'the bytes received do not match the declared SHA-256'}));
      await expectLater(
        remote.writeFile(root, 'Big.didsa', bytesOf('d', 55)),
        throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('SHA-256'))),
      );
      expect(store.livePaths('Gearbox'), isEmpty);
      await Future<void>.delayed(Duration.zero);
      expect(remote.statusOf(root).value.toSend, 1);
      final report = await remote.sync(root);
      expect(report.sent, ['Big.didsa']);
      expect(store.bytesOf('Gearbox', 'Big.didsa'), bytesOf('d', 55));
    });

    test('three syncs while the store is off, then on: nothing lost, nothing duplicated', () async {
      store.offline = true;
      await remote.writeFile(root, 'Big.didsa', bytesOf('o', 55));
      await remote.writeFile(root, 'Other.didsa', bytesOf('p', 5));
      for (var i = 0; i < 3; i++) {
        expect((await remote.sync(root)).reachable, isFalse);
      }
      store.restart();
      final report = await remote.sync(root);
      expect(report.sent, unorderedEquals(['Big.didsa', 'Other.didsa']));
      expect(store.versionOf('Gearbox', 'Big.didsa'), 1);
      expect(store.versionOf('Gearbox', 'Other.didsa'), 1);
    });
  });

  group('two devices offline on the same file', () {
    late RemoteStorageService phone;
    late ServerProjectRoot phoneRoot;

    Future<void> both() async {
      store.write('Gearbox', 'Shared.didsa', bytesOf('1', 30), device: 'Desktop');
      phone = service(device: 'Phone', folder: 'phone');
      phoneRoot = phone.rootFor('Gearbox');
      phone.beginSession(phoneRoot);
      await remote.readFile((await remote.resolve(root, 'Shared.didsa'))!);
      await phone.readFile((await phone.resolve(phoneRoot, 'Shared.didsa'))!);
      store.offline = true;
      await remote.writeFile(root, 'Shared.didsa', bytesOf('q', 30));
      await phone.writeFile(phoneRoot, 'Shared.didsa', bytesOf('p', 30));
      expect(store.versionOf('Gearbox', 'Shared.didsa'), 1);
      store.restart();
      expect((await remote.sync(root)).sent, ['Shared.didsa']);
    }

    test('the first back wins; the second is told who changed it and nothing is overwritten', () async {
      await both();
      expect(store.bytesOf('Gearbox', 'Shared.didsa'), bytesOf('q', 30));
      final report = await phone.sync(phoneRoot);
      expect(report.conflicts, hasLength(1));
      expect(report.conflicts.single.clash.modifiedBy, 'Quest 3');
      expect(store.versionOf('Gearbox', 'Shared.didsa'), 2);
      expect(store.bytesOf('Gearbox', 'Shared.didsa'), bytesOf('q', 30));
    });

    test('Keep mine lands the second device\'s file as the next version', () async {
      await both();
      await phone.sync(phoneRoot);
      await phone.resolveConflicts(phoneRoot, {'Shared.didsa': ConflictChoice.keepMine});
      await phone.sync(phoneRoot);
      expect(store.bytesOf('Gearbox', 'Shared.didsa'), bytesOf('p', 30));
      expect(store.versionOf('Gearbox', 'Shared.didsa'), 3);
    });

    test('Save as a copy keeps both files', () async {
      await both();
      await phone.sync(phoneRoot);
      final result = await phone.resolveConflicts(phoneRoot, {'Shared.didsa': ConflictChoice.saveCopy});
      await phone.sync(phoneRoot);
      expect(store.bytesOf('Gearbox', 'Shared.didsa'), bytesOf('q', 30));
      final copy = result.copies['Shared.didsa'];
      expect(copy, isNotNull);
      expect(store.bytesOf('Gearbox', copy!), bytesOf('p', 30));
    });

    test('the same edit made on both devices is no clash and is not saved twice', () async {
      store.write('Gearbox', 'Same.didsa', bytesOf('1', 30), device: 'Desktop');
      phone = service(device: 'Phone', folder: 'phone');
      phoneRoot = phone.rootFor('Gearbox');
      phone.beginSession(phoneRoot);
      await remote.readFile((await remote.resolve(root, 'Same.didsa'))!);
      await phone.readFile((await phone.resolve(phoneRoot, 'Same.didsa'))!);
      store.offline = true;
      await remote.writeFile(root, 'Same.didsa', bytesOf('z', 30));
      await phone.writeFile(phoneRoot, 'Same.didsa', bytesOf('z', 30));
      store.restart();
      await remote.sync(root);
      final report = await phone.sync(phoneRoot);
      expect(report.conflicts, isEmpty);
      expect(store.versionOf('Gearbox', 'Same.didsa'), 2);
    });
  });

  group('the size of the local copies', () {
    test('FileCache.trim removes the least recently used first, keeps what it is told to, and a read counts as a use', () async {
      final cache = FileCache(cacheDirectory: Directory('${temp.path}/trim'));
      final r = remote.rootFor('Gearbox');
      for (final name in ['old', 'mid', 'new', 'pinned']) {
        await cache.put(r, '$name.didsa', bytesOf('x', 100), serverVersion: 1);
        await Future<void>.delayed(const Duration(milliseconds: 1100)); // (modified times have a one-second grain on some file systems)
      }
      expect(await cache.sizeBytes(), 400);
      await cache.get(r, 'old.didsa'); // used just now: no longer the oldest
      final freed = await cache.trim(250, keep: {cache.keyFor(r, 'pinned.didsa')});
      expect(freed, 200);
      expect(await cache.get(r, 'mid.didsa'), isNull);
      expect(await cache.get(r, 'new.didsa'), isNull);
      expect(await cache.get(r, 'old.didsa'), isNotNull);
      expect(await cache.get(r, 'pinned.didsa'), isNotNull);
      expect(await cache.trim(0), 0); // 0 = no limit
      expect(await cache.trim(10000), 0);
    });

    test('a sync trims the copies to the limit but never what this session read, and never a save waiting to be sent', () async {
      for (final name in ['A', 'B', 'C']) {
        store.write('Gearbox', '$name.didsa', bytesOf(name.toLowerCase(), 100));
      }
      final small = RemoteStorageService(
        settings: () => StoreSettings(url: 'https://store.test', apiKey: 'store-key', deviceName: 'Quest 3'),
        httpClient: store.client,
        syncStore: SyncStore(directory: Directory('${temp.path}/small/sync')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/small/cache')),
        clock: () => now,
        treeTtl: Duration.zero,
        cacheLimitBytes: () => 150,
      );
      final smallRoot = small.rootFor('Gearbox');
      small.beginSession(smallRoot);
      // read A, B and C in an earlier session: they are cached, then the app is "closed" and a new session starts
      for (final name in ['A', 'B', 'C']) {
        await small.readFile((await small.resolve(smallRoot, '$name.didsa'))!);
      }
      small.beginSession(smallRoot);
      await small.readFile((await small.resolve(smallRoot, 'C.didsa'))!); // this session reads C
      // an unsent save is in the queue, not in the cache
      store.offline = true;
      await small.writeFile(smallRoot, 'Queued.didsa', bytesOf('q', 120));
      store.restart();
      store.write('Gearbox', 'B.didsa', bytesOf('z', 100)); // so the sync has something to do
      await small.sync(smallRoot);
      await small.trimDone;
      final cache = FileCache(cacheDirectory: Directory('${temp.path}/small/cache'));
      expect(await cache.sizeBytes(), lessThanOrEqualTo(150 + 120)); // C (kept) plus whatever else fits
      expect(await cache.get(smallRoot, 'C.didsa'), isNotNull);
      expect(store.bytesOf('Gearbox', 'Queued.didsa'), bytesOf('q', 120)); // the save waiting was sent, not removed
    });
  });
}
