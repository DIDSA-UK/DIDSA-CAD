import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

import 'project_root.dart';

/// A `FileCache.get` hit: the last bytes this cache saw for a file, plus
/// when this cache last saved them and (if known) what the source file's
/// own last-modified time was at that point.
class CachedFile {
  const CachedFile({required this.bytes, required this.cachedAt, this.lastKnownModified, this.serverVersion});

  final Uint8List bytes;
  final DateTime cachedAt;
  final DateTime? lastKnownModified;

  /// A server project's file: the store's version these bytes are (shared storage, `docs/shared-storage-scope.md` section 7: the
  /// cache is the server project's local copy). Null for a local folder's entry.
  final int? serverVersion;
}

/// The "cached last-known-good snapshot" half of the reference-staleness
/// policy (`docs/assembly-scope.md` decision #5): a `StorageService`
/// always tries the live file first; when that fails (offline network
/// drive, revoked permission, deleted file), the caller falls back to
/// whatever this cache last saw for that same `(root, relativePath)`,
/// flagged stale in the UI, and this cache re-populates itself the next
/// time a live read succeeds. Not a decision-maker itself - purely a
/// get/put/evict store; the "try live, fall back to cache, flag stale"
/// policy lives in whichever caller (the Phase 2 multi-file graph
/// composer) actually needs it.
///
/// Deliberately keyed by a hash of `(root.persistedKey, relativePath)`
/// rather than a live `FileHandle`, since a `FileHandle`'s own platform
/// locator (a SAF URI, an OS path) can become exactly the thing that's
/// unreachable when this cache is needed.
class FileCache {
  FileCache({Directory? cacheDirectory}) : _cacheDirectoryOverride = cacheDirectory;

  /// Test-only seam: a real temp `Directory` in tests avoids exercising
  /// `path_provider`'s own platform channel, the same "inject the real
  /// thing, not a mock" testing style this codebase already uses
  /// elsewhere (e.g. `PartScreen`'s injectable `documentApi`).
  final Directory? _cacheDirectoryOverride;

  Future<Directory> _cacheDir() async {
    final override = _cacheDirectoryOverride;
    if (override != null) {
      if (!await override.exists()) await override.create(recursive: true);
      return override;
    }
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'didsa-file-cache'));
    await dir.create(recursive: true);
    return dir;
  }

  /// The cache's name for a file (what [trim]'s `keep` is made of).
  String keyFor(ProjectRoot root, String relativePath) => _keyFor(root, relativePath);

  String _keyFor(ProjectRoot root, String relativePath) {
    return sha256.convert(utf8.encode('${root.persistedKey}::$relativePath')).toString();
  }

  Future<void> put(ProjectRoot root, String relativePath, Uint8List bytes, {DateTime? lastKnownModified, int? serverVersion}) async {
    final dir = await _cacheDir();
    final key = _keyFor(root, relativePath);
    await File(p.join(dir.path, '$key.bin')).writeAsBytes(bytes, flush: true);
    final meta = {
      'cachedAtMs': DateTime.now().millisecondsSinceEpoch,
      'lastKnownModifiedMs': lastKnownModified?.millisecondsSinceEpoch,
      if (serverVersion != null) 'serverVersion': serverVersion,
    };
    await File(p.join(dir.path, '$key.meta.json')).writeAsString(jsonEncode(meta));
  }

  Future<CachedFile?> get(ProjectRoot root, String relativePath) async {
    final dir = await _cacheDir();
    final key = _keyFor(root, relativePath);
    final bytesFile = File(p.join(dir.path, '$key.bin'));
    final metaFile = File(p.join(dir.path, '$key.meta.json'));
    if (!await bytesFile.exists() || !await metaFile.exists()) return null;
    try {
      await bytesFile.setLastModified(DateTime.now()); // "last used", for [trim]
    } on FileSystemException {
      // Not fatal: the entry just looks older than it is.
    }

    final Map<String, dynamic> meta;
    try {
      meta = jsonDecode(await metaFile.readAsString()) as Map<String, dynamic>;
    } on FormatException {
      return null;
    }
    final cachedAtMs = meta['cachedAtMs'] as int?;
    if (cachedAtMs == null) return null;
    final lastKnownModifiedMs = meta['lastKnownModifiedMs'] as int?;

    return CachedFile(
      bytes: await bytesFile.readAsBytes(),
      cachedAt: DateTime.fromMillisecondsSinceEpoch(cachedAtMs),
      lastKnownModified: lastKnownModifiedMs != null
          ? DateTime.fromMillisecondsSinceEpoch(lastKnownModifiedMs)
          : null,
      serverVersion: meta['serverVersion'] as int?,
    );
  }

  /// Total size of the cached copies, in bytes.
  Future<int> sizeBytes() async {
    final dir = await _cacheDir();
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is File && entity.path.endsWith('.bin')) total += await entity.length();
    }
    return total;
  }

  /// Removes the least recently used copies until the cache fits [maxBytes] (S4); [keep] (made with [keyFor]) are never removed, e.g. the
  /// files an open session read. Everything here can be fetched again from the server; nothing waiting to be sent lives in this cache.
  /// Returns how many bytes were freed.
  Future<int> trim(int maxBytes, {Set<String> keep = const {}}) async {
    if (maxBytes <= 0) return 0;
    final dir = await _cacheDir();
    final entries = <({File bin, File meta, int size, DateTime used, String key})>[];
    var total = 0;
    await for (final entity in dir.list()) {
      if (entity is! File || !entity.path.endsWith('.bin')) continue;
      final size = await entity.length();
      total += size;
      final key = p.basename(entity.path).replaceAll(RegExp(r'\.bin$'), '');
      entries.add((bin: entity, meta: File(p.join(dir.path, '$key.meta.json')), size: size, used: await entity.lastModified(), key: key));
    }
    if (total <= maxBytes) return 0;
    entries.sort((a, b) => a.used.compareTo(b.used));
    var freed = 0;
    for (final entry in entries) {
      if (total <= maxBytes) break;
      if (keep.contains(entry.key)) continue;
      await entry.bin.delete();
      if (await entry.meta.exists()) await entry.meta.delete();
      total -= entry.size;
      freed += entry.size;
    }
    return freed;
  }

  Future<void> evict(ProjectRoot root, String relativePath) async {
    final dir = await _cacheDir();
    final key = _keyFor(root, relativePath);
    final bytesFile = File(p.join(dir.path, '$key.bin'));
    final metaFile = File(p.join(dir.path, '$key.meta.json'));
    if (await bytesFile.exists()) await bytesFile.delete();
    if (await metaFile.exists()) await metaFile.delete();
  }
}
