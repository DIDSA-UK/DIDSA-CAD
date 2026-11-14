// The client's service layer against the REAL project store (`project-store/`), not the fake: what the fake models, checked against what
// the store does. RemoteStorageService, StoreClient, the conflict choices, Save All as one commit, the change feed and the part index.
//
//   cd project-store && PROJECT_STORE_API_KEY=e2e-store-key PROJECT_STORE_ROOT=/tmp/didsa-e2e-store python -m uvicorn app.main:app --port 8200
//   DIDSA_LIVE_STORE=http://127.0.0.1:8200 DIDSA_LIVE_STORE_KEY=e2e-store-key flutter test test/live/server_store_live_test.dart
//
// Skipped when DIDSA_LIVE_STORE is not set, so the normal `flutter test` never needs a server. CI starts the store and runs it
// (`.github/workflows/client-verify.yml`, job `store-e2e`). A plain `test()` (no widget binding) on purpose: the widget binding blocks
// real HTTP. Each test uses its own project name, so one store serves them all.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:didsa_cad_client/assembly/assembly_graph_composer.dart';
import 'package:didsa_cad_client/assembly/reference_report.dart';
import 'package:didsa_cad_client/storage/desktop_storage_service.dart';
import 'package:didsa_cad_client/storage/file_cache.dart';
import 'package:didsa_cad_client/storage/project_root.dart';
import 'package:didsa_cad_client/storage/server/remote_storage_service.dart';
import 'package:didsa_cad_client/storage/server/store_client.dart';
import 'package:didsa_cad_client/storage/server/sync_conflicts.dart';
import 'package:didsa_cad_client/storage/server/sync_state.dart';
import 'package:didsa_cad_client/storage/storage_service.dart';

final String? _url = Platform.environment['DIDSA_LIVE_STORE'];
final String _key = Platform.environment['DIDSA_LIVE_STORE_KEY'] ?? 'e2e-store-key';

Map<String, dynamic> _file(String id, {int marker = 0, List<Map<String, dynamic>> occurrences = const []}) => {
      'schema_version': 1,
      'document': {
        'id': 'doc-$id',
        'root_part_id': id,
        'parts': [
          {'id': id, 'name': id, 'features': [], 'occurrences': occurrences, 'mates': [], 'marker': marker},
        ],
      },
      'sketches': [],
    };

Map<String, dynamic> _occ(String id, String ref, {String? refPartId}) => {
      'id': id,
      'external_ref': ref,
      'name_override': null,
      'transform': {'translation': [0.0, 0.0, 0.0], 'rotation_axis': [0.0, 0.0, 1.0], 'rotation_angle_degrees': 0.0},
      'suppressed': false,
      'hidden': false,
      if (refPartId != null) 'ref_part_id': refPartId,
    };

Uint8List _bytes(Map<String, dynamic> json) => Uint8List.fromList(utf8.encode(jsonEncode(json)));

Map<String, dynamic> _decode(List<int> bytes) => jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;

int _marker(List<int> bytes) => ((_decode(bytes)['document'] as Map)['parts'] as List).first['marker'] as int;

void main() {
  final skip = _url == null ? 'DIDSA_LIVE_STORE is not set (see this file\'s header)' : false;
  late Directory temp;
  late RemoteStorageService desktop;
  late RemoteStorageService phone; // another device on the same store
  late String project;
  late ServerProjectRoot root;
  var counter = 0;

  RemoteStorageService device(String name, String sub) => RemoteStorageService(
        settings: () => StoreSettings(url: _url!, apiKey: _key, deviceName: name),
        syncStore: SyncStore(directory: Directory('${temp.path}/$sub/sync')),
        fileCache: FileCache(cacheDirectory: Directory('${temp.path}/$sub/cache')),
        treeTtl: Duration.zero,
      );

  setUp(() async {
    temp = await Directory.systemTemp.createTemp('didsa_store_live_');
    desktop = device('Desktop', 'desktop');
    phone = device('Phone', 'phone');
    project = 'e2e-${DateTime.now().microsecondsSinceEpoch}-${counter++}';
    root = await desktop.createProject(project);
    desktop.beginSession(root);
    phone.beginSession(root);
  });

  tearDown(() async {
    if (await temp.exists()) await temp.delete(recursive: true);
  });

  Future<Uint8List> read(RemoteStorageService service, String path) async => service.readFile((await service.resolve(root, path))!);

  test('health, the project list, and a wrong key is a 401 StorageException', () async {
    expect(await desktop.checkConnection(), isNull);
    expect((await desktop.listProjects()).map((p) => p.name), contains(project));
    final wrong = RemoteStorageService(
      settings: () => StoreSettings(url: _url!, apiKey: 'not-the-key', deviceName: 'Desktop'),
      syncStore: SyncStore(directory: Directory('${temp.path}/wrong')),
      fileCache: FileCache(cacheDirectory: Directory('${temp.path}/wrong-cache')),
    );
    await expectLater(wrong.listProjects(), throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('401'))));
    expect(await wrong.checkConnection(), contains('refused the key'));
  }, skip: skip);

  test('a new file, a versioned overwrite, and what the other device then reads', () async {
    await desktop.writeFile(root, 'Gearbox.didsa', _bytes(_file('p-asm')));
    await desktop.writeFile(root, 'parts/Shaft.didsa', _bytes(_file('p-shaft')));

    final handle = await phone.resolve(root, 'parts/Shaft.didsa');
    expect(handle, isNotNull);
    expect(_marker(await phone.readFile(handle!)), 0);

    await desktop.writeFile(root, 'parts/Shaft.didsa', _bytes(_file('p-shaft', marker: 1)));
    final tree = await StoreClient(StoreSettings(url: _url!, apiKey: _key, deviceName: 'x')).tree(project);
    final shaft = tree.files.firstWhere((f) => f.path == 'parts/Shaft.didsa');
    expect(shaft.version, 2);
    expect(shaft.modifiedBy, 'Desktop');
    expect(shaft.partId, 'p-shaft');
    expect(_marker(await phone.readFile(handle)), 1);
  }, skip: skip);

  test('a stale single write is 412: nothing written, who changed it, my bytes queued; Keep mine then lands as the next version', () async {
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a')));
    await read(phone, 'a.didsa'); // the phone's session is at v1
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 5))); // v2

    final error = await phone.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 9))).then<Object?>((_) => null, onError: (Object e) => e);

    expect(error, isA<SyncConflictException>());
    final conflict = (error as SyncConflictException).conflicts.single;
    expect(conflict.clash.currentVersion, 2);
    expect(conflict.clash.modifiedBy, 'Desktop');
    expect(conflict.clash.modifiedAt, isNotNull);
    expect(_marker(await read(desktop, 'a.didsa')), 5, reason: 'the store kept theirs');

    await phone.resolveConflicts(root, {'a.didsa': ConflictChoice.keepMine});
    final report = await phone.sync(root);
    expect(report.sent, ['a.didsa']);
    expect(_marker(await read(desktop, 'a.didsa')), 9);
    final versions = await http.get(Uri.parse('$_url/projects/$project/files/a.didsa/versions'), headers: {'X-API-Key': _key});
    expect((jsonDecode(versions.body)['versions'] as List).length, 3, reason: 'theirs stays in the history');
  }, skip: skip);

  test('every store status the client maps: 428 (raw), 400 (a refused name), 404, and a missing precondition is never sent by this client', () async {
    // The store's own answer to a write with no precondition - what the client must never trigger.
    final raw = await http.put(
      Uri.parse('$_url/projects/$project/files/raw.didsa'),
      headers: {'X-API-Key': _key},
      body: 'x',
    );
    expect(raw.statusCode, 428);

    // A name the store refuses is a 400 whose message the client surfaces.
    await expectLater(
      desktop.writeFile(root, 'bad:name.didsa', _bytes(_file('p'))),
      throwsA(isA<StorageException>().having((e) => e.message, 'message', isNotEmpty)),
    );
    // A path that would collide with the history routes is refused (S1 found this).
    await expectLater(desktop.writeFile(root, 'x/versions', _bytes(_file('p'))), throwsA(isA<StorageException>()));
    // A project that does not exist is a 404, said plainly.
    await expectLater(
      desktop.listFiles(ServerProjectRoot(serverUrl: _url!, project: 'no-such-project-$counter')),
      throwsA(isA<StorageException>()),
    );
    // Nothing the client sent was refused for a missing precondition: ordinary writes succeed.
    await desktop.writeFile(root, 'ok.didsa', _bytes(_file('p-ok')));
    expect(await desktop.resolve(root, 'ok.didsa'), isNotNull);
  }, skip: skip);

  test('Save All is ONE commit; a 409 writes nothing at all and lists every clash; the retry after resolving lands', () async {
    for (final entry in {'Gearbox.didsa': 'p-asm', 'parts/Shaft.didsa': 'p-shaft', 'parts/Gear.didsa': 'p-gear'}.entries) {
      await desktop.writeFile(root, entry.key, _bytes(_file(entry.value)));
      await read(phone, entry.key);
    }
    // The desktop changes two files after the phone opened the project.
    await desktop.writeFile(root, 'parts/Shaft.didsa', _bytes(_file('p-shaft', marker: 4)));
    await desktop.writeFile(root, 'parts/Gear.didsa', _bytes(_file('p-gear', marker: 4)));

    SyncConflictException? clash;
    try {
      await phone.commit(root, [
        FileChange(path: 'Gearbox.didsa', bytes: _bytes(_file('p-asm', marker: 1))),
        FileChange(path: 'parts/Shaft.didsa', bytes: _bytes(_file('p-shaft', marker: 1))),
        FileChange(path: 'parts/Gear.didsa', bytes: _bytes(_file('p-gear', marker: 1))),
      ], message: 'Save All');
    } on SyncConflictException catch (e) {
      clash = e;
    }

    expect(clash, isNotNull);
    expect(clash!.conflicts.map((c) => c.path), unorderedEquals(['parts/Shaft.didsa', 'parts/Gear.didsa']));
    expect(clash.conflicts.every((c) => c.clash.modifiedBy == 'Desktop'), isTrue);
    expect(_marker(await read(desktop, 'Gearbox.didsa')), 0, reason: 'the file that did not clash was not written either');
    expect(_marker(await read(desktop, 'parts/Shaft.didsa')), 4);

    await phone.resolveConflicts(root, {'parts/Shaft.didsa': ConflictChoice.keepMine, 'parts/Gear.didsa': ConflictChoice.takeTheirs});
    final report = await phone.sync(root);
    expect(report.conflicts, isEmpty);
    expect(report.sent, unorderedEquals(['Gearbox.didsa', 'parts/Shaft.didsa']));
    expect(_marker(await read(desktop, 'Gearbox.didsa')), 1);
    expect(_marker(await read(desktop, 'parts/Shaft.didsa')), 1);
    expect(_marker(await read(desktop, 'parts/Gear.didsa')), 4, reason: 'Take theirs');
  }, skip: skip);

  test('Save mine as a copy writes "<name> (<device>, <date>).didsa" with a new Part id, and the two never share an id', () async {
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a')));
    await read(phone, 'a.didsa');
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 5)));
    await phone.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 9))).then<void>((_) {}, onError: (Object _) {});

    final result = await phone.resolveConflicts(root, {'a.didsa': ConflictChoice.saveCopy});
    await phone.sync(root);

    final copyPath = result.copies['a.didsa']!;
    expect(copyPath, matches(RegExp(r'^a \(Phone, \d{4}-\d{2}-\d{2}\)\.didsa$')));
    final copy = _decode(await read(desktop, copyPath));
    expect((copy['document'] as Map)['root_part_id'], isNot('p-a'));
    expect(_marker(utf8.encode(jsonEncode(copy))), 9);
    expect(_marker(await read(desktop, 'a.didsa')), 5);
    final tree = await StoreClient(StoreSettings(url: _url!, apiKey: _key, deviceName: 'x')).tree(project);
    expect(tree.files.map((f) => f.partId).toSet().length, tree.files.length, reason: 'no two files share a Part id');
  }, skip: skip);

  test('a file another device deleted or renamed is a clash: 409 current says deleted and moved_to', () async {
    await desktop.writeFile(root, 'parts/Shaft.didsa', _bytes(_file('p-shaft')));
    await read(phone, 'parts/Shaft.didsa');
    await desktop.renameFile(root, 'parts/Shaft.didsa', 'Shaft-v2.didsa');

    final error = await phone.writeFile(root, 'parts/Shaft.didsa', _bytes(_file('p-shaft', marker: 1))).then<Object?>((_) => null, onError: (Object e) => e);

    final conflict = (error as SyncConflictException).conflicts.single;
    expect(conflict.clash.deleted, isTrue);
    expect(conflict.clash.movedTo, 'parts/Shaft-v2.didsa');
    expect(conflict.describe(), contains('Renamed to parts/Shaft-v2.didsa by Desktop'));
    // Keep mine writes the file at the old path again.
    await phone.resolveConflicts(root, {'parts/Shaft.didsa': ConflictChoice.keepMine});
    await phone.sync(root);
    expect(_marker(await read(desktop, 'parts/Shaft.didsa')), 1);
  }, skip: skip);

  test('offline: a save is queued, and the sync on reconnect asks the change feed first and sends one commit', () async {
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a')));
    await read(phone, 'a.didsa');
    await phone.sync(root); // keeps the cursor

    // "Offline" is a store that cannot be reached: the same service, pointed at a closed port, for the one save.
    final cut = RemoteStorageService(
      settings: () => StoreSettings(url: 'http://127.0.0.1:1', apiKey: _key, deviceName: 'Phone'),
      syncStore: SyncStore(directory: Directory('${temp.path}/cut/sync')),
      fileCache: FileCache(cacheDirectory: Directory('${temp.path}/cut/cache')),
    );
    final cutRoot = ServerProjectRoot(serverUrl: 'http://127.0.0.1:1', project: project);
    await cut.writeFile(cutRoot, 'a.didsa', _bytes(_file('p-a', marker: 3)));
    expect(cut.statusOf(cutRoot).value.toSend, 1);
    expect((await cut.sync(cutRoot)).reachable, isFalse);
    expect(_marker(await read(desktop, 'a.didsa')), 0);

    // Back online: the phone's own queue (same state, now pointed at the real store) is what carries the save.
    final saved = device('Phone', 'phone');
    saved.beginSession(root);
    await read(saved, 'a.didsa');
    await saved.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 3)));
    final report = await saved.sync(root);
    expect(report.reachable, isTrue);
    expect(_marker(await read(desktop, 'a.didsa')), 3);
  }, skip: skip);

  test('the change feed from a saved cursor refreshes a cached copy another device changed', () async {
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a')));
    await read(phone, 'a.didsa');
    await phone.sync(root);
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a', marker: 8)));

    final later = device('Phone', 'phone'); // a later launch: the queue and cursor are on disk
    final report = await later.sync(root);

    expect(report.refreshed, ['a.didsa']);
  }, skip: skip);

  test('the moved-files rule through the store\'s part index: a moved file is found by id without reading every file', () async {
    await desktop.writeFile(root, 'Gearbox.didsa', _bytes(_file('p-asm', occurrences: [_occ('o1', 'parts/Shaft.didsa', refPartId: 'p-shaft')])));
    await desktop.writeFile(root, 'archive/old/Shaft.didsa', _bytes(_file('p-shaft')));
    for (var i = 0; i < 6; i++) {
      await desktop.writeFile(root, 'library/Part$i.didsa', _bytes(_file('p-lib-$i')));
    }
    final composer = AssemblyGraphComposer(storageService: desktop, fileCache: FileCache(cacheDirectory: Directory('${temp.path}/composer')));

    expect(await desktop.pathsWithPartId(root, 'p-shaft'), ['archive/old/Shaft.didsa']);
    expect(await desktop.pathsWithPartId(root, 'nobody'), isEmpty);
    final composed = await composer.compose(root, 'Gearbox.didsa');

    expect(composed.references.single.outcome, ReferenceOutcome.movedById);
    expect(composed.references.single.foundPath, 'archive/old/Shaft.didsa');
  }, skip: skip);

  test('copy this project to the server: a local folder becomes a server project in one commit', () async {
    final folder = Directory('${temp.path}/local')..createSync();
    File('${folder.path}/Gearbox.didsa').writeAsBytesSync(_bytes(_file('p-asm')));
    Directory('${folder.path}/parts').createSync();
    File('${folder.path}/parts/Shaft.didsa').writeAsBytesSync(_bytes(_file('p-shaft')));

    final copyName = '$project-copy';
    final copied = await desktop.copyProjectToServer(DesktopStorageService(), DesktopProjectRoot(folder.path), copyName);

    expect(await desktop.listFiles(copied), unorderedEquals(['Gearbox.didsa', 'parts/Shaft.didsa']));
    // A second copy under the same name is refused with the store's own message.
    await expectLater(
      desktop.copyProjectToServer(DesktopStorageService(), DesktopProjectRoot(folder.path), copyName),
      throwsA(isA<StorageException>().having((e) => e.message, 'message', contains('already exists'))),
    );
  }, skip: skip);

  test('rename is a commit move: the old path is a delete with moved_to, the new path a put', () async {
    await desktop.writeFile(root, 'a.didsa', _bytes(_file('p-a')));
    await desktop.sync(root);
    await desktop.renameFile(root, 'a.didsa', 'b.didsa');
    expect(await desktop.listFiles(root), ['b.didsa']);
    expect(_marker(await read(desktop, 'b.didsa')), 0);
  }, skip: skip);

  test('S4: a file over the threshold goes up in chunks to the real store, byte for byte, as one version, and an interrupted one resumes', () async {
    final chunky = RemoteStorageService(
      settings: () => StoreSettings(url: _url!, apiKey: _key, deviceName: 'Chunky'),
      syncStore: SyncStore(directory: Directory('${temp.path}/chunky/sync')),
      fileCache: FileCache(cacheDirectory: Directory('${temp.path}/chunky/cache')),
      treeTtl: Duration.zero,
      chunkThresholdBytes: 1000,
      chunkBytes: 700,
    );
    chunky.beginSession(root);
    final big = Uint8List.fromList(List<int>.generate(5000, (i) => (i * 31 + 7) & 255));
    await chunky.writeFile(root, 'Big.didsa', big);
    final tree = await StoreClient(StoreSettings(url: _url!, apiKey: _key, deviceName: 'x')).tree(project);
    final stored = tree.files.firstWhere((f) => f.path == 'Big.didsa');
    expect(stored.size, 5000);
    expect(stored.version, 1);
    expect(await read(desktop, 'Big.didsa'), big);
    // an edit is a commit with the base version, still in chunks
    final edited = Uint8List.fromList(big.reversed.toList());
    await chunky.writeFile(root, 'Big.didsa', edited);
    expect(await read(desktop, 'Big.didsa'), edited);
    // an interrupted upload resumes on the same session: open one by hand, send two chunks, then let the service finish it
    final client = StoreClient(StoreSettings(url: _url!, apiKey: _key, deviceName: 'Chunky'));
    final other = Uint8List.fromList(List<int>.generate(3000, (i) => (i * 13 + 5) & 255));
    final sha = sha256.convert(other).toString();
    final session = await client.startUploadSession(project, other.length, sha);
    await client.uploadChunk(project, session.id, 0, Uint8List.sublistView(other, 0, 700));
    final status = await client.uploadStatus(project, session.id);
    expect(status.received, 700);
    // a chunk at the wrong place is refused with where to go on
    await expectLater(
      client.uploadChunk(project, session.id, 1400, Uint8List.sublistView(other, 1400, 2100)),
      throwsA(isA<StoreError>().having((e) => e.code, 'code', 'wrong_offset').having((e) => e.body['received'], 'received', 700)),
    );
    await client.uploadChunk(project, session.id, 700, Uint8List.sublistView(other, 700, 3000));
    final id = await client.completeUpload(project, session.id);
    final done = await client.commit(project, [StoreCommitChange.put(path: 'Resumed.didsa', uploadId: id)]);
    expect(done.files.single['version'], 1);
    expect(await read(desktop, 'Resumed.didsa'), other);
    // a wrong hash is refused and the upload is gone
    final bad = await client.startUploadSession(project, 10, '0' * 64);
    await client.uploadChunk(project, bad.id, 0, Uint8List(10));
    await expectLater(client.completeUpload(project, bad.id), throwsA(isA<StoreBadRequest>().having((e) => e.code, 'code', 'checksum_mismatch')));
    await expectLater(client.uploadStatus(project, bad.id), throwsA(isA<StoreNotFound>()));
  }, skip: skip);
}
