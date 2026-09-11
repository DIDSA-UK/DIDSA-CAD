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
  const CachedFile({required this.bytes, required this.cachedAt, this.lastKnownModified});

  final Uint8List bytes;
  final DateTime cachedAt;
  final DateTime? lastKnownModified;
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
    if (override != null) return override;
    final base = await getApplicationCacheDirectory();
    final dir = Directory(p.join(base.path, 'didsa-file-cache'));
    await dir.create(recursive: true);
    return dir;
  }

  String _keyFor(ProjectRoot root, String relativePath) {
    return sha256.convert(utf8.encode('${root.persistedKey}::$relativePath')).toString();
  }

  Future<void> put(ProjectRoot root, String relativePath, Uint8List bytes, {DateTime? lastKnownModified}) async {
    final dir = await _cacheDir();
    final key = _keyFor(root, relativePath);
    await File(p.join(dir.path, '$key.bin')).writeAsBytes(bytes, flush: true);
    final meta = {
      'cachedAtMs': DateTime.now().millisecondsSinceEpoch,
      'lastKnownModifiedMs': lastKnownModified?.millisecondsSinceEpoch,
    };
    await File(p.join(dir.path, '$key.meta.json')).writeAsString(jsonEncode(meta));
  }

  Future<CachedFile?> get(ProjectRoot root, String relativePath) async {
    final dir = await _cacheDir();
    final key = _keyFor(root, relativePath);
    final bytesFile = File(p.join(dir.path, '$key.bin'));
    final metaFile = File(p.join(dir.path, '$key.meta.json'));
    if (!await bytesFile.exists() || !await metaFile.exists()) return null;

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
    );
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
