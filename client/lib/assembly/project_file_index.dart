import 'dart:convert';

import '../storage/native_file_listing.dart';
import '../storage/part_id_index.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';
import 'file_lookup_rule.dart';
import 'relative_path.dart' show isNativeProjectFileName;

/// A native file's root Part id (`document.root_part_id`, else its first Part's id) from its decoded JSON, or null.
String? rootPartIdOf(Object? payload) {
  final document = payload is Map ? payload['document'] : null;
  if (document is! Map) return null;
  final root = document['root_part_id'];
  if (root is String && root.isNotEmpty) return root;
  final parts = document['parts'];
  if (parts is List && parts.isNotEmpty && parts.first is Map) {
    final id = (parts.first as Map)['id'];
    if (id is String && id.isNotEmpty) return id;
  }
  return null;
}

/// Finding moved files (`docs/moved-files-scope.md` section 3): every native file under the project folder with its root Part id,
/// for [findFile]'s steps 2 and 3. [build] runs only when a reference misses (or a mismatch needs checking), never on every open;
/// reading a file's id means opening it, so each id is cached per file and last-modified time for as long as this object lives.
class ProjectFileIndex {
  ProjectFileIndex(this._storage, {this.maxFiles = 5000});

  final StorageService _storage;
  final int maxFiles;

  final Map<String, ({DateTime? modified, String? id})> _ids = {};

  String _key(ProjectRoot root, String relativePath) => '${root.persistedKey}|$relativePath';

  /// The root Part id of the file at [relativePath], or null when it is missing or can't be read as a native file.
  Future<String?> partIdAt(ProjectRoot root, String relativePath) async {
    // A server project: the store's index knows every file's id, so no file is read.
    final Object indexed = _storage;
    if (indexed is PartIdIndex && indexed.hasPartIndex(root)) {
      try {
        return await indexed.partIdAt(root, relativePath);
      } on StorageException {
        return null;
      }
    }
    try {
      final handle = await _storage.resolve(root, relativePath);
      if (handle == null) return null;
      final modified = await _storage.lastModified(handle);
      final cached = _ids[_key(root, relativePath)];
      if (cached != null && modified != null && cached.modified == modified) return cached.id;
      String? id;
      try {
        id = rootPartIdOf(jsonDecode(utf8.decode(await _storage.readFile(handle))));
      } on FormatException {
        id = null;
      }
      _ids[_key(root, relativePath)] = (modified: modified, id: id);
      return id;
    } on StorageException {
      return null;
    }
  }

  /// The paths whose root Part id is [partId], asked of the store's part index (`GET .../parts/{part_id}`) so nothing is read or
  /// listed; null when [root] has no such index (a local folder).
  Future<List<String>?> pathsWithPartId(ProjectRoot root, String partId) async {
    final Object indexed = _storage;
    if (indexed is! PartIdIndex || !indexed.hasPartIndex(root)) return null;
    try {
      return await indexed.pathsWithPartId(root, partId);
    } on StorageException {
      return null;
    }
  }

  /// Drops what is cached for [relativePath] (it was just written, so its id may have changed).
  void forget(ProjectRoot root, String relativePath) => _ids.remove(_key(root, relativePath));

  /// Every native file under [root] (at most [maxFiles]), each with its root Part id, in path order.
  Future<List<IndexedFile>> build(ProjectRoot root) async {
    // A server project: one list from the store (each file's id is in it) instead of reading every file.
    final Object indexed = _storage;
    if (indexed is PartIdIndex && indexed.hasPartIndex(root)) {
      try {
        final entries = await indexed.indexEntries(root) ?? const [];
        return [
          for (final entry in entries)
            if (isNativeProjectFileName(entry.path) && !entry.path.split('/').any((segment) => segment.startsWith('.')))
              IndexedFile(entry.path, entry.partId),
        ].take(maxFiles).toList()
          ..sort((a, b) => a.path.compareTo(b.path));
      } on StorageException {
        return const [];
      }
    }
    final List<String> paths;
    try {
      paths = [
        for (final path in await _storage.listNativeFiles(root))
          if (!path.split('/').any((segment) => segment.startsWith('.'))) path,
      ]..sort();
    } on StorageException {
      return const [];
    }
    return [
      for (final path in paths.take(maxFiles)) IndexedFile(path, await partIdAt(root, path)),
    ];
  }
}
