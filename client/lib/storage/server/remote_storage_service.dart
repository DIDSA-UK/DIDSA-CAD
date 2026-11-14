/// `StorageService` for a project on the project store (`project-store/`; `docs/shared-storage-scope.md` sections 6 and 7), so Open,
/// Save, Save All and the assembly composer work on a server project exactly as on a folder.
///
/// How a server project behaves:
///
/// * **Reads are live**, and each read keeps a local copy (`FileCache`) with the version it is. **Offline**, a read answers from
///   that copy and `resolve` / `listFiles` from the file list kept at the last contact.
/// * **A save names the version it replaces** (`If-Match`). That version is the one this device's copy is based on: the version
///   of the file the first time it was read in this session ([beginSession]), or the version a later write of it produced. So a
///   composer that re-reads a file does not move the base of a Part that is open in the session.
/// * **Nothing a save wrote is ever lost.** A save is first staged in the queue (`SyncStore`, bytes on disk), then sent. Sent: the
///   store has it. Store unreachable: it stays "to send" and goes on the next [sync]. Store refused it as stale (412 for one file,
///   409 for a commit): it stays in the queue flagged as a clash, with what the store says is current, and a
///   [SyncConflictException] tells the caller; the user's choice ([resolveConflicts]) then the next [sync] finishes it.
/// * **Save All is one commit** ([commit]): every changed file is uploaded, then one all-or-nothing `POST .../commit`.
/// * **[sync]** asks the change feed from the saved cursor first (a small answer; "nothing changed" costs no tree), flags queued
///   saves the feed shows are now stale, refreshes cached copies of files others changed, then sends the queue as one commit.
///
/// No store statuses are handled by the callers above: each becomes a `StorageException` (a clash a `SyncConflictException`).
library;

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;

import '../../assembly/project_file_index.dart' show rootPartIdOf;
import '../../assembly/relative_path.dart';
import '../../config.dart';
import '../file_cache.dart';
import '../file_handle.dart';
import '../part_id_index.dart';
import '../project_root.dart';
import '../storage_service.dart';
import 'store_client.dart';
import 'sync_conflicts.dart';
import 'sync_state.dart';

/// Requests over this size can be refused by a Cloudflare tunnel (its free plan's documented limit; not measured here). A file over
/// [kChunkThresholdBytes] goes up in chunks instead (S4), so only a store that cannot take chunks is explained by this limit.
const int kTunnelLimitBytes = 100 * 1024 * 1024;

/// A file over this goes up in chunks (headroom under the tunnel's 100 MB request limit), [kChunkBytes] at a time (the store's own advice,
/// `chunk_size`, wins when it is smaller).
const int kChunkThresholdBytes = 90 * 1024 * 1024;
const int kChunkBytes = 32 * 1024 * 1024;

/// A chunk the store did not answer is tried this many times in a row before the sync gives up (the upload resumes at the next sync).
const int kChunkRetries = 3;

/// What a status chip shows for one server project.
class SyncSummary {
  const SyncSummary({this.online, this.toSend = 0, this.clash = 0, this.lastSyncedAt, this.keptCopies = 0, this.problems = const {}});

  /// null: the store has not been called yet this session.
  final bool? online;
  final int toSend;
  final int clash;
  final DateTime? lastSyncedAt;

  /// Files whose "mine" bytes are kept after a Take theirs, until the next successful sync.
  final int keptCopies;

  /// Queued saves the store would not take (too large, a refused name): path -> message.
  final Map<String, String> problems;

  bool get allSynced => toSend == 0 && clash == 0;

  @override
  bool operator ==(Object other) =>
      other is SyncSummary &&
      other.online == online &&
      other.toSend == toSend &&
      other.clash == clash &&
      other.lastSyncedAt == lastSyncedAt &&
      other.keptCopies == keptCopies &&
      other.problems.length == problems.length;

  @override
  int get hashCode => Object.hash(online, toSend, clash, lastSyncedAt, keptCopies, problems.length);
}

/// What one [RemoteStorageService.sync] did.
class SyncReport {
  const SyncReport({required this.reachable, this.sent = const [], this.conflicts = const [], this.refreshed = const [], this.error});

  final bool reachable;
  final List<String> sent;
  final List<SyncConflict> conflicts;

  /// Cached copies refreshed because another device changed the file.
  final List<String> refreshed;
  final String? error;
}

/// What resolving did: [reload] is true when the open session no longer matches the store (Take theirs, Save a copy): the caller
/// should offer to reopen the project.
class ResolveResult {
  const ResolveResult({required this.reload, this.copies = const {}});

  final bool reload;

  /// original path -> the path the copy was written to.
  final Map<String, String> copies;
}

class _Mutex {
  Future<void> _tail = Future.value();

  Future<T> run<T>(Future<T> Function() action) {
    final done = Completer<T>();
    final previous = _tail;
    _tail = done.future.then((_) {}, onError: (_) {});
    previous.then((_) async {
      try {
        done.complete(await action());
      } catch (error, stack) {
        done.completeError(error, stack);
      }
    });
    return done.future;
  }
}

/// The store does not list `uploads.chunked` (it predates S4): a big file cannot be sent.
class _NoChunking implements Exception {}

class RemoteStorageService implements StorageService, PartIdIndex {
  RemoteStorageService({
    StoreSettings Function()? settings,
    http.Client? httpClient,
    SyncStore? syncStore,
    FileCache? fileCache,
    DateTime Function()? clock,
    this.treeTtl = const Duration(seconds: 5),
    this.tunnelLimitBytes = kTunnelLimitBytes,
    this.chunkThresholdBytes = kChunkThresholdBytes,
    this.chunkBytes = kChunkBytes,
    int Function()? cacheLimitBytes,
  })  : _cacheLimitBytes = cacheLimitBytes ?? _cacheLimitFromConfig,
         _settings = settings ?? _settingsFromConfig,
        _httpClient = httpClient,
        _store = syncStore ?? SyncStore(),
        _cache = fileCache ?? FileCache(),
        _clock = clock ?? DateTime.now;

  static StoreSettings _settingsFromConfig() =>
      StoreSettings(url: ApiConfig.storeUrl, apiKey: ApiConfig.storeApiKey, deviceName: ApiConfig.effectiveDeviceName);

  final StoreSettings Function() _settings;
  final http.Client? _httpClient;
  final SyncStore _store;
  final FileCache _cache;
  final DateTime Function() _clock;

  /// Above this a failed upload is explained as the tunnel's limit (a test lowers it).
  final int tunnelLimitBytes;

  /// How much disk the local copies may take (S4); 0 = no limit. Default: the setting ([ApiConfig.cacheLimitMb]).
  final int Function() _cacheLimitBytes;

  static int _cacheLimitFromConfig() => ApiConfig.cacheLimitMb * 1024 * 1024;

  /// A file over [chunkThresholdBytes] goes up in pieces of [chunkBytes] (tests lower both).
  final int chunkThresholdBytes;
  final int chunkBytes;

  /// How long a fetched file list is trusted before `resolve` / `listFiles` fetch it again.
  final Duration treeTtl;

  final Map<String, _Mutex> _locks = {};
  final Map<String, DateTime> _treeAt = {};
  final Map<String, Set<String>> _touched = {};
  final Map<String, Set<String>> _freshMine = {};
  final Map<String, Map<String, ({String id, String sha, DateTime at})>> _uploads = {};
  final Map<String, ValueNotifier<SyncSummary>> _notifiers = {};
  final Map<String, bool> _online = {};

  // ------------------------------------------------------------------------------------------ settings and the project list

  StoreSettings get settings => _settings();

  String _deviceName() {
    final name = _settings().deviceName;
    return name.isEmpty ? ApiConfig.defaultDeviceName() : name;
  }

  /// The store's address and key are both set.
  bool get isConfigured => _settings().isConfigured;

  StoreClient _clientFor(String serverUrl) {
    final current = _settings();
    if (!current.isConfigured) {
      throw StorageException('Set the project store address and key in the server settings first.');
    }
    if (_normalise(current.url) != _normalise(serverUrl)) {
      throw StorageException(
        'This project is on $serverUrl but the server settings point at ${current.url}. Change the store address back, or open the project from the store that is set.',
      );
    }
    return StoreClient(current, httpClient: _httpClient);
  }

  static String _normalise(String url) => url.trim().replaceAll(RegExp(r'/+$'), '').toLowerCase();

  Future<T> _call<T>(String serverUrl, Future<T> Function(StoreClient client) action) async {
    final client = _clientFor(serverUrl);
    try {
      return await action(client);
    } finally {
      client.close();
    }
  }

  Future<T> _callFor<T>(ServerProjectRoot root, Future<T> Function(StoreClient client) action) => _call(root.serverUrl, action);

  /// The root for [project] on the store set in the server settings.
  ServerProjectRoot rootFor(String project) => ServerProjectRoot(serverUrl: _normaliseKeepCase(_settings().url), project: project);

  static String _normaliseKeepCase(String url) => url.trim().replaceAll(RegExp(r'/+$'), '');

  /// `GET /projects`. Throws `StoreOfflineException` when the store cannot be reached.
  Future<List<StoreProject>> listProjects() async {
    final url = _normaliseKeepCase(_settings().url);
    try {
      return await _call(url, (client) => client.listProjects());
    } on StoreUnreachable catch (error) {
      throw StoreOfflineException('The project store could not be reached.', cause: error);
    } on StoreError catch (error) {
      throw _asStorage(error);
    }
  }

  /// `POST /projects`. A name that is taken (or one the store refuses) throws a `StorageException` with the store's message.
  Future<ServerProjectRoot> createProject(String name) async {
    final url = _normaliseKeepCase(_settings().url);
    try {
      await _call(url, (client) => client.createProject(name.trim()));
    } on StoreUnreachable catch (error) {
      throw StoreOfflineException('The project store could not be reached.', cause: error);
    } on StoreError catch (error) {
      throw _asStorage(error);
    }
    return ServerProjectRoot(serverUrl: url, project: name.trim());
  }

  /// Checks the address and key (`GET /health`). Null when it answered, else the message to show.
  Future<String?> checkConnection({String? url, String? key}) async {
    final base = _settings();
    final tryUrl = url ?? base.url;
    final client = StoreClient(
      StoreSettings(url: tryUrl, apiKey: key ?? base.apiKey, deviceName: base.deviceName),
      httpClient: _httpClient,
    );
    try {
      await client.health();
      return null;
    } on StoreUnreachable {
      return 'The project store could not be reached at $tryUrl.';
    } on StoreAuthError {
      return 'The project store refused the key.';
    } on StoreError catch (error) {
      return 'The project store answered: ${error.detail}';
    } finally {
      client.close();
    }
  }

  // ------------------------------------------------------------------------------------------ status

  /// The chip's data for [root]; a `ValueNotifier` the chip listens to.
  ValueNotifier<SyncSummary> statusOf(ServerProjectRoot root) {
    final notifier = _notifiers.putIfAbsent(root.persistedKey, () => ValueNotifier(const SyncSummary()));
    unawaited(_publish(root));
    return notifier;
  }

  Future<void> _publish(ServerProjectRoot root) async {
    final state = await _store.load(root);
    final notifier = _notifiers.putIfAbsent(root.persistedKey, () => ValueNotifier(const SyncSummary()));
    notifier.value = SyncSummary(
      online: _online[root.persistedKey],
      toSend: state.queue.values.where((q) => q.clash == null).length,
      clash: state.queue.values.where((q) => q.clash != null).length,
      lastSyncedAt: state.lastSyncedAt,
      keptCopies: state.mine.length,
      problems: {for (final e in _problems(root.persistedKey).entries) e.key: e.value},
    );
  }

  final Map<String, Map<String, String>> _problemMessages = {};

  Map<String, String> _problems(String key) => _problemMessages.putIfAbsent(key, () => {});

  void _setOnline(ServerProjectRoot root, bool online) => _online[root.persistedKey] = online;

  /// The sync state of one file, for a file list.
  Future<SyncFileState> fileState(ServerProjectRoot root, String path) async => (await _store.load(root)).stateOf(path);

  // ------------------------------------------------------------------------------------------ session

  /// Starts a session on [root] (a project is opened): from now the base version of a file is the version of its first read.
  void beginSession(ServerProjectRoot root) {
    _touched[root.persistedKey] = {};
    _treeAt.remove(root.persistedKey);
  }

  // ------------------------------------------------------------------------------------------ StorageService

  @override
  Future<ProjectRoot> pickOrCreateProjectRoot({String suggestedName = 'didsa/projects'}) =>
      throw StorageException('A server project is chosen from File > Server projects.');

  @override
  Future<ProjectRoot?> lastUsedProjectRoot() async => null;

  ServerProjectRoot _server(ProjectRoot root) {
    if (root is! ServerProjectRoot) throw StorageException('RemoteStorageService given a non-server ProjectRoot: $root');
    return root;
  }

  _Mutex _lock(ServerProjectRoot root) => _locks.putIfAbsent(root.persistedKey, _Mutex.new);

  /// Fetches the file list unless a fresh one is held. False: the store could not be reached (the list kept at the last contact is used).
  Future<bool> _ensureTree(ServerProjectRoot root, {bool force = false}) async {
    final key = root.persistedKey;
    final at = _treeAt[key];
    if (!force && at != null && _clock().difference(at) < treeTtl) return _online[key] ?? true;
    final state = await _store.load(root);
    try {
      final tree = await _callFor(root, (client) => client.tree(root.project));
      state.tree
        ..clear()
        ..addAll({for (final f in tree.files) f.path: f});
      state.cursor ??= tree.cursor;
      _treeAt[key] = _clock();
      _setOnline(root, true);
      await _store.save(root);
      await _publish(root);
      return true;
    } on StoreUnreachable {
      _treeAt[key] = _clock();
      _setOnline(root, false);
      await _publish(root);
      return false;
    } on StoreError catch (error) {
      throw _asStorage(error);
    }
  }

  @override
  Future<FileHandle?> resolve(ProjectRoot root, String relativePath) async {
    final server = _server(root);
    await _ensureTree(server);
    final state = await _store.load(server);
    final queued = state.queue[relativePath];
    final listed = state.tree[relativePath];
    if (queued != null || listed != null) {
      final base = state.bases[relativePath];
      return ServerFileHandle(
        root: server,
        relativePath: relativePath,
        version: listed?.version ?? base?.version,
        sha256: listed?.sha256 ?? base?.sha256,
      );
    }
    // Offline and never listed (a project opened before the list was kept): a file that has a local copy still opens.
    if (_online[server.persistedKey] == false && state.tree.isEmpty && await _cache.get(server, relativePath) != null) {
      return ServerFileHandle(root: server, relativePath: relativePath);
    }
    return null;
  }

  @override
  Future<Uint8List> readFile(FileHandle handle) async {
    if (handle is! ServerFileHandle) throw StorageException('RemoteStorageService given a non-server FileHandle: $handle');
    final root = handle.root;
    final path = handle.relativePath;
    final state = await _store.load(root);
    if (state.queue.containsKey(path)) {
      final queued = await _store.getQueued(root, path);
      if (queued != null) return queued;
    }
    try {
      final fetched = await _callFor(root, (client) => client.getFile(root.project, path));
      _setOnline(root, true);
      await _noteRead(root, state, path, fetched);
      return fetched.bytes;
    } on StoreUnreachable {
      _setOnline(root, false);
      unawaited(_publish(root));
      final cached = await _cache.get(root, path);
      if (cached != null) return cached.bytes;
      throw StoreOfflineException('$path is not available offline: the project store cannot be reached and this device has no copy.');
    } on StoreNotFound {
      throw StorageException('File not found: $path');
    } on StoreError catch (error) {
      throw _asStorage(error, path: path);
    }
  }

  Future<void> _noteRead(ServerProjectRoot root, ProjectSyncState state, String path, StoreFetched fetched) async {
    final key = root.persistedKey;
    final touched = _touched.putIfAbsent(key, () => {});
    final current = StoreFile(
      path: path,
      version: fetched.version,
      sha256: fetched.sha256,
      size: fetched.bytes.length,
      modifiedAt: state.tree[path]?.modifiedAt,
      modifiedBy: state.tree[path]?.modifiedBy ?? '',
      partId: state.tree[path]?.partId,
    );
    var changed = false;
    // The base of a file this session already read (or wrote) stays where it was: see the class comment.
    if (!touched.contains(path)) {
      touched.add(path);
      if (state.bases[path]?.version != current.version || state.bases[path]?.sha256 != current.sha256) {
        state.bases[path] = current;
        changed = true;
      }
    }
    final listed = state.tree[path];
    if (listed == null || listed.version != current.version) {
      state.tree[path] = current;
      changed = true;
    }
    await _cache.put(root, path, fetched.bytes, serverVersion: fetched.version);
    if (changed) await _store.save(root);
  }

  @override
  Future<DateTime?> lastModified(FileHandle handle) async {
    if (handle is! ServerFileHandle) return null;
    final state = await _store.load(handle.root);
    return state.queue[handle.relativePath]?.queuedAt ?? state.tree[handle.relativePath]?.modifiedAt;
  }

  @override
  Future<bool> exists(FileHandle handle) async {
    try {
      return await resolve(handle.root, handle.relativePath) != null;
    } on StorageException {
      return false;
    }
  }

  @override
  Future<List<String>> listFiles(ProjectRoot root, {String? extensionFilter}) async {
    final server = _server(root);
    final online = await _ensureTree(server);
    final state = await _store.load(server);
    if (!online && state.tree.isEmpty && state.queue.isEmpty) {
      throw StoreOfflineException('The project store cannot be reached and this device has no copy of ${server.project}.');
    }
    final paths = {...state.tree.keys, ...state.queue.keys};
    return [
      for (final path in paths)
        if (extensionFilter == null || path.toLowerCase().endsWith(extensionFilter.toLowerCase())) path,
    ];
  }

  // ------------------------------------------------------------------------------------------ the moved-files index

  @override
  bool hasPartIndex(ProjectRoot root) => root is ServerProjectRoot;

  @override
  Future<String?> partIdAt(ProjectRoot root, String path) async {
    if (root is! ServerProjectRoot) return null;
    await _ensureTree(root);
    final state = await _store.load(root);
    if (state.queue.containsKey(path)) {
      final bytes = await _store.getQueued(root, path);
      return bytes == null ? null : _partIdOfBytes(bytes);
    }
    return state.tree[path]?.partId;
  }

  @override
  Future<List<({String path, String? partId})>?> indexEntries(ProjectRoot root) async {
    if (root is! ServerProjectRoot) return null;
    await _ensureTree(root);
    final state = await _store.load(root);
    final entries = <({String path, String? partId})>[];
    for (final path in {...state.tree.keys, ...state.queue.keys}) {
      final queued = state.queue[path];
      String? id = state.tree[path]?.partId;
      if (queued != null) {
        final bytes = await _store.getQueued(root, path);
        id = bytes == null ? id : _partIdOfBytes(bytes);
      }
      entries.add((path: path, partId: id));
    }
    return entries;
  }

  static String? _partIdOfBytes(Uint8List bytes) {
    try {
      return rootPartIdOf(jsonDecode(utf8.decode(bytes)));
    } on FormatException {
      return null;
    }
  }

  @override
  Future<List<String>?> pathsWithPartId(ProjectRoot root, String partId) async {
    if (root is! ServerProjectRoot) return null;
    final state = await _store.load(root);
    final paths = <String>{};
    // A save not sent yet is not in the store's index: its own id is read from its bytes.
    final queuedIds = <String, String?>{};
    for (final path in state.queue.keys) {
      final bytes = await _store.getQueued(root, path);
      queuedIds[path] = bytes == null ? null : _partIdOfBytes(bytes);
    }
    try {
      final found = await _callFor(root, (client) => client.parts(root.project, partId));
      _setOnline(root, true);
      paths.addAll(found.map((f) => f.path).where((path) => !state.queue.containsKey(path)));
    } on StoreUnreachable {
      _setOnline(root, false);
      // Offline: the file list kept at the last contact carries each file's id.
      paths.addAll([
        for (final f in state.tree.values)
          if (f.partId == partId && !state.queue.containsKey(f.path)) f.path,
      ]);
    } on StoreError catch (error) {
      throw _asStorage(error);
    }
    paths.addAll([for (final e in queuedIds.entries) if (e.value == partId) e.key]);
    return paths.toList()..sort();
  }

  // ------------------------------------------------------------------------------------------ writes

  static String _sha(Uint8List bytes) => sha256.convert(bytes).toString();

  @override
  bool supportsCommit(ProjectRoot root) => root is ServerProjectRoot;

  /// Stages [bytes] for [path] in the queue (replacing a queued save of the same path, which keeps its base).
  Future<QueuedSave> _stage(ServerProjectRoot root, ProjectSyncState state, String path, Uint8List bytes, int? baseVersion, {bool haveBase = false}) async {
    final existing = state.queue[path];
    final int? base = haveBase ? baseVersion : (existing != null ? existing.baseVersion : state.bases[path]?.version);
    final entry = QueuedSave(path: path, baseVersion: base, queuedAt: _clock());
    await _store.putQueued(root, path, bytes);
    state.queue[path] = entry;
    _problems(root.persistedKey).remove(path);
    await _store.save(root);
    return entry;
  }

  @override
  Future<FileHandle> writeFile(ProjectRoot root, String relativePath, Uint8List bytes, {int? baseVersion}) async {
    final server = _server(root);
    _checkPath(relativePath);
    return _lock(server).run(() async {
      final state = await _store.load(server);
      final sha = _sha(bytes);
      if (!state.queue.containsKey(relativePath) && baseVersion == null && state.bases[relativePath]?.sha256 == sha) {
        // Nothing changed since this copy was read or written: nothing to save.
        return _handle(server, state, relativePath);
      }
      final entry = await _stage(server, state, relativePath, bytes, baseVersion, haveBase: baseVersion != null);
      if (bytes.length > chunkThresholdBytes) return _writeBig(server, state, relativePath, entry);
      try {
        final info = await _callFor(
          server,
          (client) => client.putFile(server.project, relativePath, bytes, ifMatch: entry.baseVersion),
        );
        _setOnline(server, true);
        await _recordWritten(server, state, info, bytes);
        await _publish(server);
        return _handle(server, state, relativePath);
      } on StorePreconditionFailed catch (error) {
        _setOnline(server, true);
        final clash = SyncClash.fromCurrent(error.current, baseWasCreate: entry.baseVersion == null);
        entry.clash = clash;
        await _store.save(server);
        await _publish(server);
        throw SyncConflictException([SyncConflict(path: relativePath, clash: clash, queuedAt: entry.queuedAt)]);
      } on StoreUnreachable {
        if (bytes.length > tunnelLimitBytes && await _answersWithoutChunking(server)) {
          throw await _tooLarge(server, state, relativePath, bytes.length);
        }
        _setOnline(server, false);
        await _publish(server);
        return _handle(server, state, relativePath);
      } on StoreTooLarge catch (error) {
        if (!error.fromStore) return _writeBig(server, state, relativePath, entry); // a tunnel refused the body: try it in pieces
        throw await _tooLarge(server, state, relativePath, bytes.length, storeSaid: error.detail);
      } on StoreBadRequest catch (error) {
        // A name or body the store will never take: keep nothing queued that can never be sent.
        await _dropQueued(server, state, relativePath);
        await _publish(server);
        throw _asStorage(error, path: relativePath);
      } on StoreAuthError catch (error) {
        await _publish(server);
        throw _asStorage(error, path: relativePath);
      } on StoreError catch (error) {
        await _publish(server);
        throw _asStorage(error, path: relativePath);
      }
    });
  }

  /// One file too big for a single request: a commit of just that file (so its base version is still checked), sent in chunks.
  Future<FileHandle> _writeBig(ServerProjectRoot server, ProjectSyncState state, String path, QueuedSave entry) async {
    try {
      final outcome = await _sendQueue(server, state, retryClashes: false, only: path);
      if (outcome.queued.contains(path)) await _publish(server);
      return _handle(server, state, path);
    } on SyncConflictException catch (error) {
      throw SyncConflictException([for (final c in error.conflicts) if (c.path == path) c]);
    }
  }

  FileHandle _handle(ServerProjectRoot root, ProjectSyncState state, String path) => ServerFileHandle(
        root: root,
        relativePath: path,
        version: state.bases[path]?.version ?? state.tree[path]?.version,
        sha256: state.bases[path]?.sha256,
      );

  Future<void> _recordWritten(ServerProjectRoot root, ProjectSyncState state, StoreFile info, Uint8List bytes) async {
    state.tree[info.path] = info;
    state.bases[info.path] = info;
    _touched.putIfAbsent(root.persistedKey, () => {}).add(info.path);
    state.queue.remove(info.path);
    _problems(root.persistedKey).remove(info.path);
    await _store.deleteQueued(root, info.path);
    await _cache.put(root, info.path, bytes, serverVersion: info.version);
    await _store.save(root);
  }

  Future<void> _dropQueued(ServerProjectRoot root, ProjectSyncState state, String path) async {
    state.queue.remove(path);
    _problems(root.persistedKey).remove(path);
    await _store.deleteQueued(root, path);
    await _store.save(root);
  }

  /// The store answers but cannot take a big file in pieces: then a failed upload of a file over the tunnel's limit is most likely the
  /// tunnel. (A store that CAN chunk gets the file in chunks instead, so that explanation would be wrong for it.)
  Future<bool> _answersWithoutChunking(ServerProjectRoot root) async {
    try {
      return !await _callFor(root, (client) => _canChunk(client));
    } on StoreUnreachable {
      return false;
    } on StoreError {
      return true;
    }
  }

  static String _sizeText(int bytes) =>
      bytes >= 1024 * 1024 ? '${(bytes / (1024 * 1024)).toStringAsFixed(0)} MB' : '${(bytes / 1024).toStringAsFixed(0)} KB';

  /// [storeSaid]: the store itself answered 413 (its own limit, [detail]); otherwise the upload was cut off or refused by something in
  /// front of it, which for a file this big is the Cloudflare tunnel's request limit.
  Future<StorageException> _tooLarge(ServerProjectRoot root, ProjectSyncState state, String path, int size, {String? storeSaid, bool oldStore = false}) async {
    final message = storeSaid != null
        ? '$path is ${_sizeText(size)}, which is too large for the project store ($storeSaid). '
            'The file was not saved to the server; this device keeps your save in its queue until you discard it.'
        : oldStore
            ? '$path is ${_sizeText(size)}. This project store is too old to take a file over 100 MB in pieces (it does not list uploads.chunked): update the store. '
                'The file was not saved to the server; this device keeps your save in its queue until you discard it.'
            : '$path is ${_sizeText(size)}. A server behind a Cloudflare tunnel can refuse an upload over 100 MB, and this project store cannot take it in pieces. '
                'The file was not saved to the server; this device keeps your save in its queue until you discard it.';
    _problems(root.persistedKey)[path] = message;
    await _publish(root);
    return StorageException(message);
  }

  void _checkPath(String path) {
    if (path.isEmpty || path.startsWith('/') || path.contains('\\') || path.split('/').any((s) => s == '..' || s.isEmpty)) {
      throw StorageException('"$path" is not a path the project store accepts.');
    }
  }

  @override
  Future<CommitOutcome> commit(ProjectRoot root, List<FileChange> changes, {String? message}) async {
    final server = _server(root);
    for (final change in changes) {
      _checkPath(change.path);
    }
    return _lock(server).run(() async {
      final state = await _store.load(server);
      for (final change in changes) {
        final unchanged = !state.queue.containsKey(change.path) && change.baseVersion == null && state.bases[change.path]?.sha256 == _sha(change.bytes);
        if (unchanged) continue;
        await _stage(server, state, change.path, change.bytes, change.baseVersion, haveBase: change.baseVersion != null);
      }
      final outcome = await _sendQueue(server, state, retryClashes: true, message: message);
      return CommitOutcome(
        sent: [
          for (final change in changes)
            if (!outcome.queued.contains(change.path)) change.path,
        ],
        queued: [for (final path in outcome.queued) if (changes.any((c) => c.path == path)) path],
      );
    });
  }

  /// Sends every queued save as one commit. Returns what stayed queued (the store could not be reached); throws
  /// [SyncConflictException] (every clash, nothing written) or a [StorageException].
  Future<CommitOutcome> _sendQueue(ServerProjectRoot root, ProjectSyncState state, {required bool retryClashes, String? message, String? only}) async {
    if (state.queue.isEmpty) return const CommitOutcome();
    final wanted = only == null ? state.queue.values.toList() : [if (state.queue[only] != null) state.queue[only]!];
    if (!retryClashes) {
      final clashes = _clashes(state).where((c) => only == null || c.path == only).toList();
      if (clashes.isNotEmpty) throw SyncConflictException(clashes);
    } else {
      for (final entry in wanted) {
        entry.clash = null;
      }
    }
    final entries = wanted;
    final key = root.persistedKey;
    final uploads = _uploads.putIfAbsent(key, () => {});
    try {
      return await _callFor(root, (client) async {
        var retried = false;
        while (true) {
          final changes = <StoreCommitChange>[];
          final bytesOf = <String, Uint8List>{};
          for (final entry in entries) {
            final bytes = await _store.getQueued(root, entry.path);
            if (bytes == null) {
              // The bytes are gone (the app's storage was cleared): nothing can be sent for it.
              state.queue.remove(entry.path);
              continue;
            }
            bytesOf[entry.path] = bytes;
            final sha = _sha(bytes);
            final known = uploads[entry.path];
            String uploadId;
            if (bytes.length <= chunkThresholdBytes && known != null && known.sha == sha && _clock().difference(known.at) < const Duration(minutes: 50)) {
              uploadId = known.id;
            } else {
              try {
                uploadId = await _uploadBytes(client, root, state, entry.path, bytes, sha);
                if (bytes.length <= chunkThresholdBytes && !state.uploadSessions.containsKey(entry.path)) {
                  uploads[entry.path] = (id: uploadId, sha: sha, at: _clock());
                }
              } on StoreTooLarge catch (error) {
                throw await _tooLarge(root, state, entry.path, bytes.length, storeSaid: error.fromStore ? error.detail : null);
              } on _NoChunking {
                throw await _tooLarge(root, state, entry.path, bytes.length, oldStore: true);
              } on StoreUnreachable {
                if (bytes.length > tunnelLimitBytes && await _answersWithoutChunking(root)) {
                  throw await _tooLarge(root, state, entry.path, bytes.length);
                }
                rethrow;
              }
            }
            changes.add(StoreCommitChange.put(path: entry.path, uploadId: uploadId, baseVersion: entry.baseVersion));
          }
          if (changes.isEmpty) {
            await _store.save(root);
            return const CommitOutcome();
          }
          try {
            final result = await client.commit(root.project, changes, message: message);
            _setOnline(root, true);
            for (final file in result.files) {
              final info = StoreFile.fromJson(file);
              await _recordWritten(root, state, info, bytesOf[info.path] ?? Uint8List(0));
              uploads.remove(info.path);
              if (state.uploadSessions.remove(info.path) != null) await _store.save(root);
            }
            for (final entry in entries) {
              // A result that did not name a file (cannot happen with a store that answers every change): do not keep it queued.
              if (state.queue.containsKey(entry.path) && bytesOf.containsKey(entry.path)) {
                state.queue.remove(entry.path);
                await _store.deleteQueued(root, entry.path);
              }
            }
            if (state.queue.isEmpty) await _dropMine(root, state);
            state.lastSyncedAt = _clock();
            await _store.save(root);
            await _publish(root);
            return CommitOutcome(sent: [for (final entry in entries) entry.path]);
          } on StoreCommitConflict catch (error) {
            _setOnline(root, true);
            for (final conflict in error.conflicts) {
              final queued = state.queue[conflict['path']];
              if (queued != null) queued.clash = SyncClash.fromConflict(conflict);
            }
            await _store.save(root);
            await _publish(root);
            throw SyncConflictException(_clashes(state));
          } on StoreBadRequest catch (error) {
            if (error.code == 'unknown_upload' && !retried) {
              // An upload expired (the store keeps them an hour): upload everything again, once.
              retried = true;
              uploads.clear();
              state.uploadSessions.clear();
              continue;
            }
            rethrow;
          }
        }
      });
    } on StoreUnreachable {
      _setOnline(root, false);
      await _publish(root);
      return CommitOutcome(queued: [for (final entry in entries) entry.path]);
    } on StoreError catch (error) {
      for (final entry in entries) {
        _problems(key)[entry.path] = error.detail;
      }
      await _publish(root);
      throw _asStorage(error);
    }
  }

  /// A queued save whose bytes ARE the store's current version is not a clash and is not sent: it is that version. It happens when a
  /// commit landed but its reply was lost (the save stayed queued), and when another device made exactly the same edit (S4).
  Future<void> _adoptEqual(ServerProjectRoot root, ProjectSyncState state) async {
    for (final entry in state.queue.values.toList()) {
      final listed = state.tree[entry.path];
      if (listed == null) continue;
      final bytes = await _store.getQueued(root, entry.path);
      if (bytes == null || _sha(bytes) != listed.sha256) continue;
      state.bases[entry.path] = listed;
      state.queue.remove(entry.path);
      state.uploadSessions.remove(entry.path);
      _problems(root.persistedKey).remove(entry.path);
      await _store.deleteQueued(root, entry.path);
      await _cache.put(root, entry.path, bytes, serverVersion: listed.version);
      _touched.putIfAbsent(root.persistedKey, () => {}).add(entry.path);
    }
  }

  Future<bool> _canChunk(StoreClient client) async => (await client.health()).contains('uploads.chunked');

  /// The bytes of one queued file are on the store, ready for a commit: the id. Up to [chunkThresholdBytes] in one request; a bigger file,
  /// or one a tunnel refused, in chunks that resume where the store says it got to (S4).
  Future<String> _uploadBytes(StoreClient client, ServerProjectRoot root, ProjectSyncState state, String path, Uint8List bytes, String sha) async {
    if (bytes.length > chunkThresholdBytes) return _uploadChunked(client, root, state, path, bytes, sha);
    try {
      return await client.upload(root.project, bytes);
    } on StoreTooLarge catch (error) {
      if (error.fromStore) rethrow;
      return _uploadChunked(client, root, state, path, bytes, sha); // a tunnel with a lower limit than we thought
    }
  }

  Future<String> _uploadChunked(StoreClient client, ServerProjectRoot root, ProjectSyncState state, String path, Uint8List bytes, String sha) async {
    if (!await _canChunk(client)) throw _NoChunking();
    final known = state.uploadSessions[path];
    String? id;
    var received = 0;
    var chunk = chunkBytes;
    if (known != null && known.sha == sha && known.size == bytes.length && _clock().millisecondsSinceEpoch - known.atMs < const Duration(minutes: 50).inMilliseconds) {
      try {
        final status = await client.uploadStatus(root.project, known.id);
        if (status.complete) return known.id;
        id = known.id;
        received = status.received;
      } on StoreNotFound {
        state.uploadSessions.remove(path); // it expired
      }
    }
    if (id == null) {
      final made = await client.startUploadSession(root.project, bytes.length, sha);
      id = made.id;
      if (made.chunkSize > 0 && made.chunkSize < chunk) chunk = made.chunkSize;
      state.uploadSessions[path] = UploadSession(id: id, sha: sha, size: bytes.length, atMs: _clock().millisecondsSinceEpoch);
      await _store.save(root); // before the first chunk: a closed app finds the session again
    }
    var failures = 0;
    while (received < bytes.length) {
      final end = received + chunk < bytes.length ? received + chunk : bytes.length;
      try {
        final status = await client.uploadChunk(root.project, id, received, Uint8List.sublistView(bytes, received, end));
        received = status.received;
        failures = 0;
        state.uploadSessions[path]?.atMs = _clock().millisecondsSinceEpoch;
      } on StoreUnreachable {
        if (++failures >= kChunkRetries) rethrow; // the session stays saved: the next sync resumes
      } on StoreNotFound {
        state.uploadSessions.remove(path);
        await _store.save(root);
        rethrow;
      } on StoreError catch (error) {
        if (error.status == 409 && error.code == 'wrong_offset') {
          // A reply was lost: the store says where it really is. A store that keeps naming the offset it was just sent will not agree: give up, never loop.
          final there = (error.body['received'] as num?)?.toInt() ?? 0;
          if (there == received || there > bytes.length) failures++;
          if (failures >= kChunkRetries) {
            throw StorageException('The project store and this device disagree about how much of $path was uploaded; it will be tried again at the next sync.');
          }
          received = there.clamp(0, bytes.length);
          continue;
        }
        rethrow;
      }
    }
    await _store.save(root);
    try {
      return await client.completeUpload(root.project, id);
    } on StoreError catch (error) {
      if (error is StoreBadRequest || error is StoreNotFound) {
        state.uploadSessions.remove(path); // damaged on the way, or gone: it cannot be repaired, the next attempt starts again
        await _store.save(root);
      }
      rethrow;
    }
  }

  List<SyncConflict> _clashes(ProjectSyncState state) => [
        for (final entry in state.queue.values)
          if (entry.clash != null) SyncConflict(path: entry.path, clash: entry.clash!, queuedAt: entry.queuedAt),
      ];

  // ------------------------------------------------------------------------------------------ rename

  @override
  Future<FileHandle> renameFile(ProjectRoot root, String relativePath, String newFileName) async {
    final server = _server(root);
    final newPath = siblingRelativePath(relativePath, newFileName);
    _checkPath(newPath);
    return _lock(server).run(() async {
      final state = await _store.load(server);
      if (state.queue.containsKey(relativePath)) {
        throw StorageException('$relativePath has a save that is not on the server yet. Sync first, then rename it.');
      }
      await _ensureTree(server, force: true);
      final listed = state.tree[relativePath];
      if (listed == null) throw StorageException('Cannot rename $relativePath: no such file');
      if (state.tree.containsKey(newPath)) throw StorageException('A file already exists at $newPath');
      final base = state.bases[relativePath]?.version ?? listed.version;
      try {
        final result = await _callFor(
          server,
          (client) => client.commit(server.project, [StoreCommitChange.move(path: relativePath, to: newPath, baseVersion: base)]),
        );
        _setOnline(server, true);
        for (final file in result.files) {
          if (file['deleted'] == true) {
            state.tree.remove(file['path']);
            state.bases.remove(file['path']);
          } else {
            final info = StoreFile.fromJson(file);
            state.tree[info.path] = info;
            state.bases[info.path] = info;
            _touched.putIfAbsent(server.persistedKey, () => {}).add(info.path);
          }
        }
        final cached = await _cache.get(server, relativePath);
        if (cached != null) {
          await _cache.put(server, newPath, cached.bytes, serverVersion: state.bases[newPath]?.version);
          await _cache.evict(server, relativePath);
        }
        await _store.save(server);
        await _publish(server);
        return _handle(server, state, newPath);
      } on StoreCommitConflict catch (error) {
        final first = error.conflicts.isEmpty ? null : SyncClash.fromConflict(error.conflicts.first);
        final who = first == null || first.modifiedBy.isEmpty ? 'another device' : first.modifiedBy;
        throw StorageException('$relativePath was changed on the server by $who. Reopen it before renaming.');
      } on StoreUnreachable catch (error) {
        _setOnline(server, false);
        await _publish(server);
        throw StoreOfflineException('Renaming needs the project store: it cannot be reached.', cause: error);
      } on StoreError catch (error) {
        throw _asStorage(error, path: relativePath);
      }
    });
  }

  // ------------------------------------------------------------------------------------------ conflicts

  /// The saves the store refused, each with what it said is current.
  Future<List<SyncConflict>> conflicts(ServerProjectRoot root) async => _clashes(await _store.load(root));

  /// Applies the user's choice per file ([choices] names the paths to settle; others stay as they are). Does not send: call [sync]
  /// after, which sends the whole queue as one commit. Needs the store for Take theirs and Save a copy (theirs is fetched first;
  /// nothing changes if that fails).
  Future<ResolveResult> resolveConflicts(ServerProjectRoot root, Map<String, ConflictChoice> choices) async {
    return _lock(root).run(() async {
      final state = await _store.load(root);
      var reload = false;
      final copies = <String, String>{};
      for (final entry in choices.entries) {
        final path = entry.key;
        final queued = state.queue[path];
        if (queued == null) continue;
        final clash = queued.clash;
        switch (entry.value) {
          case ConflictChoice.keepMine:
            if (clash != null && !clash.canKeepMine) {
              throw StorageException('Keep mine is not possible for $path: ${clash.reason == 'path_conflict' ? 'a file or folder is in the way' : clash.reason}.');
            }
            queued.baseVersion = (clash == null || clash.deleted || clash.reason == 'missing') ? null : clash.currentVersion;
            // The store's version this save has now been weighed against: the feed's report of that same change is not a new clash.
            queued.reconciled = clash?.currentVersion;
            queued.clash = null;
          case ConflictChoice.takeTheirs:
            final mine = await _store.getQueued(root, path);
            await _loadTheirs(root, state, path, clash);
            if (mine != null) await _keepMine(root, state, path, mine);
            await _dropQueued(root, state, path);
            reload = true;
          case ConflictChoice.saveCopy:
            final mine = await _store.getQueued(root, path);
            if (mine == null) break;
            final copyPath = conflictCopyPath(
              path,
              _deviceName(),
              _clock(),
              (candidate) => state.tree.containsKey(candidate) || state.queue.containsKey(candidate) || copies.containsValue(candidate),
            );
            await _loadTheirs(root, state, path, clash);
            await _dropQueued(root, state, path);
            await _stage(root, state, copyPath, remintNativeBytes(mine), null, haveBase: true);
            copies[path] = copyPath;
            reload = true;
        }
      }
      await _store.save(root);
      await _publish(root);
      return ResolveResult(reload: reload, copies: copies);
    });
  }

  /// Makes the local copy of [path] the store's current one (or removes it when the store has none).
  Future<void> _loadTheirs(ServerProjectRoot root, ProjectSyncState state, String path, SyncClash? clash) async {
    final gone = clash != null && (clash.deleted || clash.reason == 'missing');
    if (gone) {
      state.bases.remove(path);
      state.tree.remove(path);
      await _cache.evict(root, path);
      return;
    }
    if (clash != null && clash.reason == 'path_conflict') return;
    try {
      final fetched = await _callFor(root, (client) => client.getFile(root.project, path));
      _setOnline(root, true);
      final info = StoreFile(
        path: path,
        version: fetched.version,
        sha256: fetched.sha256,
        size: fetched.bytes.length,
        modifiedAt: clash?.modifiedAt,
        modifiedBy: clash?.modifiedBy ?? '',
      );
      state.bases[path] = info;
      state.tree[path] = info;
      _touched.putIfAbsent(root.persistedKey, () => {}).add(path);
      await _cache.put(root, path, fetched.bytes, serverVersion: fetched.version);
    } on StoreUnreachable catch (error) {
      _setOnline(root, false);
      throw StoreOfflineException('Taking theirs needs the project store: it cannot be reached.', cause: error);
    } on StoreNotFound {
      // It went away since the refusal: the same as theirs being a delete.
      state.bases.remove(path);
      state.tree.remove(path);
      await _cache.evict(root, path);
    } on StoreError catch (error) {
      throw _asStorage(error, path: path);
    }
  }

  Future<void> _keepMine(ServerProjectRoot root, ProjectSyncState state, String path, Uint8List bytes) async {
    await _store.putMine(root, path, bytes);
    state.mine[path] = _clock();
    _freshMine.putIfAbsent(root.persistedKey, () => {}).add(path);
  }

  Future<void> _dropMine(ServerProjectRoot root, ProjectSyncState state, {bool keepFresh = true}) async {
    final fresh = keepFresh ? (_freshMine[root.persistedKey] ?? const <String>{}) : const <String>{};
    for (final path in state.mine.keys.toList()) {
      if (fresh.contains(path)) continue;
      state.mine.remove(path);
      await _store.deleteMine(root, path);
    }
    _freshMine.remove(root.persistedKey);
  }

  /// The paths whose bytes were kept after Take theirs and not yet dropped by a later sync.
  Future<List<String>> keptCopies(ServerProjectRoot root) async => (await _store.load(root)).mine.keys.toList()..sort();

  Future<Uint8List?> keptCopy(ServerProjectRoot root, String path) => _store.getMine(root, path);

  /// Puts a kept copy back as a file of its own (`<name> (<device>, <date>).didsa`, new Part id), queued to send. Returns its path.
  Future<String> restoreKeptCopyAsFile(ServerProjectRoot root, String path) async {
    return _lock(root).run(() async {
      final state = await _store.load(root);
      final mine = await _store.getMine(root, path);
      if (mine == null) throw StorageException('No kept copy of $path.');
      final copyPath = conflictCopyPath(
        path,
        _deviceName(),
        _clock(),
        (candidate) => state.tree.containsKey(candidate) || state.queue.containsKey(candidate),
      );
      await _stage(root, state, copyPath, remintNativeBytes(mine), null, haveBase: true);
      await _store.deleteMine(root, path);
      state.mine.remove(path);
      await _store.save(root);
      await _publish(root);
      return copyPath;
    });
  }

  /// Gives up a queued save (one the store will not take, or one the user no longer wants). The local copy keeps the file as it was
  /// last read from the store.
  Future<void> discardQueued(ServerProjectRoot root, String path) => _lock(root).run(() async {
        final state = await _store.load(root);
        await _dropQueued(root, state, path);
        await _publish(root);
      });

  // ------------------------------------------------------------------------------------------ sync

  /// Brings this device and the store level: the change feed from the saved cursor, then the queue as one commit. Never throws for an
  /// unreachable store (the report says so); a clash is in the report and flagged on the queued save.
  Future<SyncReport> sync(ServerProjectRoot root) => _lock(root).run(() => _sync(root));

  /// Removes the least recently used local copies when they take more than the limit; the files this session read or wrote stay. A save
  /// waiting to be sent is in the sync store, not in this cache, and is never touched.
  Future<void> _trimCache(ServerProjectRoot root) async {
    final limit = _cacheLimitBytes();
    if (limit <= 0) return;
    final keep = {for (final path in _touched[root.persistedKey] ?? const <String>{}) _cache.keyFor(root, path)};
    await _cache.trim(limit, keep: keep);
  }

  Future<SyncReport> _sync(ServerProjectRoot root) async {
    final report = await _syncInner(root);
    if (report.reachable) await _trimCache(root);
    return report;
  }

  Future<SyncReport> _syncInner(ServerProjectRoot root) async {
    final state = await _store.load(root);
    final key = root.persistedKey;
    final refreshed = <String>[];
    try {
      await _callFor(root, (client) async {
        final cursor = state.cursor;
        if (cursor == null) {
          final tree = await client.tree(root.project);
          state.tree
            ..clear()
            ..addAll({for (final f in tree.files) f.path: f});
          state.cursor = tree.cursor;
          _treeAt[key] = _clock();
          return;
        }
        var since = cursor;
        final latest = <String, StoreChange>{};
        try {
          while (true) {
            final page = await client.changes(root.project, since);
            for (final change in page.changes) {
              latest[change.path] = change;
            }
            since = page.cursor;
            if (!page.more) break;
          }
        } on StoreBadRequest catch (error) {
          if (error.code != 'bad_cursor') rethrow;
          // A cursor the store does not know (the store was restored from a backup, say): compare with the whole tree instead.
          final tree = await client.tree(root.project);
          state.tree
            ..clear()
            ..addAll({for (final f in tree.files) f.path: f});
          _treeAt[key] = _clock();
          for (final queued in state.queue.values) {
            final listed = tree.files.where((f) => f.path == queued.path).firstOrNull;
            final base = queued.baseVersion;
            if (base == null ? listed != null : (listed == null || listed.version != base)) {
              queued.clash ??= SyncClash(
                reason: listed == null ? 'deleted' : (base == null ? 'exists' : 'changed'),
                currentVersion: listed?.version,
                deleted: listed == null,
                modifiedBy: listed?.modifiedBy ?? '',
                modifiedAt: listed?.modifiedAt,
              );
            }
          }
          state.cursor = tree.cursor;
          return;
        }
        if (latest.isNotEmpty) {
          final tree = await client.tree(root.project);
          state.tree
            ..clear()
            ..addAll({for (final f in tree.files) f.path: f});
          _treeAt[key] = _clock();
        }
        final touched = _touched.putIfAbsent(key, () => {});
        for (final change in latest.values) {
          if (change.device == _settings().deviceName && change.version == state.bases[change.path]?.version) continue;
          final queued = state.queue[change.path];
          if (queued != null) {
            final base = queued.baseVersion;
            final seen = [base ?? 0, queued.reconciled ?? 0].reduce((a, b) => a > b ? a : b);
            if (queued.clash == null && change.version > seen) {
              queued.clash = SyncClash(
                reason: change.op == 'put' ? (base == null ? 'exists' : 'changed') : 'deleted',
                currentVersion: change.version,
                deleted: change.op != 'put',
                movedTo: change.movedTo,
                modifiedBy: change.device,
                modifiedAt: change.at,
              );
            }
            continue;
          }
          // No unsent save of it here: if this device holds a copy that the session has not read, bring the copy level.
          if (change.op == 'put' && !touched.contains(change.path) && await _cache.get(root, change.path) != null) {
            try {
              final fetched = await client.getFile(root.project, change.path);
              state.bases[change.path] = StoreFile(
                path: change.path,
                version: fetched.version,
                sha256: fetched.sha256,
                size: fetched.bytes.length,
                modifiedAt: change.at,
                modifiedBy: change.device,
              );
              await _cache.put(root, change.path, fetched.bytes, serverVersion: fetched.version);
              refreshed.add(change.path);
            } on StoreNotFound {
              // Deleted again since.
            }
          } else if (change.op != 'put' && !touched.contains(change.path)) {
            state.bases.remove(change.path);
            await _cache.evict(root, change.path);
          }
        }
        await _adoptEqual(root, state);
        state.cursor = since;
      });
      _setOnline(root, true);
      await _store.save(root);
    } on StoreUnreachable {
      _setOnline(root, false);
      await _publish(root);
      return const SyncReport(reachable: false);
    } on StoreError catch (error) {
      await _publish(root);
      return SyncReport(reachable: true, error: _asStorage(error).message);
    }

    final known = _clashes(state);
    if (known.isNotEmpty) {
      await _publish(root);
      return SyncReport(reachable: true, conflicts: known, refreshed: refreshed);
    }
    if (state.queue.isEmpty) {
      await _dropMine(root, state);
      state.lastSyncedAt = _clock();
      await _store.save(root);
      await _publish(root);
      return SyncReport(reachable: true, refreshed: refreshed);
    }
    try {
      final outcome = await _sendQueue(root, state, retryClashes: false);
      await _publish(root);
      return SyncReport(reachable: outcome.queued.isEmpty, sent: outcome.sent, refreshed: refreshed);
    } on SyncConflictException catch (error) {
      return SyncReport(reachable: true, conflicts: error.conflicts, refreshed: refreshed);
    } on StorageException catch (error) {
      return SyncReport(reachable: true, error: error.message, refreshed: refreshed);
    }
  }

  // ------------------------------------------------------------------------------------------ copy a folder to the server

  /// "Copy this project to the server": a new project named [project] holding every file of [localRoot] (read through [local]),
  /// written as one commit. Hidden files and folders (a name starting with a dot) are left out. Returns the new root.
  Future<ServerProjectRoot> copyProjectToServer(
    StorageService local,
    ProjectRoot localRoot,
    String project, {
    void Function(int done, int total)? onProgress,
  }) async {
    final paths = [
      for (final path in await local.listFiles(localRoot))
        if (!path.split('/').any((segment) => segment.startsWith('.'))) path,
    ]..sort();
    final root = await createProject(project);
    beginSession(root);
    final changes = <FileChange>[];
    for (var i = 0; i < paths.length; i++) {
      final handle = await local.resolve(localRoot, paths[i]);
      if (handle == null) continue;
      changes.add(FileChange(path: paths[i], bytes: await local.readFile(handle)));
      onProgress?.call(i + 1, paths.length);
    }
    try {
      final outcome = await commit(root, changes, message: 'Copied from ${localRoot.displayName}');
      if (outcome.queued.isNotEmpty) {
        // The store went away after the project was made: the files wait in the queue and go on the next sync.
      }
    } on SyncConflictException {
      rethrow;
    } on StorageException {
      // A file the store refuses (a name, a size): the new project would be left half-queued for ever, so give the queue up.
      final state = await _store.load(root);
      for (final path in state.queue.keys.toList()) {
        await _dropQueued(root, state, path);
      }
      await _publish(root);
      rethrow;
    }
    return root;
  }

  // ------------------------------------------------------------------------------------------ errors

  /// A store status turned into the message a person reads. A 428 is this client's own bug (it always sends a precondition).
  StorageException _asStorage(StoreError error, {String? path}) {
    final where = path == null ? '' : '$path: ';
    if (error is StoreAuthError) {
      return StorageException('The project store refused the key (401). Check the store key in the server settings.', cause: error);
    }
    if (error is StorePreconditionRequired) {
      return StorageException(
        'The project store refused a write that named no version (428). This is a bug in the app, not something you did: ${error.detail}',
        cause: error,
      );
    }
    if (error is StoreTooLarge) {
      return StorageException('${where}The project store refused the file as too large: ${error.detail}', cause: error);
    }
    if (error is StoreBadRequest) return StorageException('$where${error.detail}', cause: error);
    if (error is StoreNotFound) return StorageException('$where${error.detail}', cause: error);
    return StorageException('${where}The project store answered ${error.status}: ${error.detail}', cause: error);
  }
}
