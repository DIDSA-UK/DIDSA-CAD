import '../storage/project_root.dart';

/// "Changed on disk meanwhile?" (`docs/shared-storage-scope.md` section 7, decision S0-8): the modified time each file of a LOCAL
/// folder had when this session last read or wrote it. Save All compares it with the file's modified time now and asks the user
/// before overwriting a file that changed since (DIDSA-VR's `project_save.gd` does the same by modified time). A file this session
/// never read or wrote has no stamp and is not checked. A server project has versions instead and never uses this.
class LocalFileStamps {
  final Map<String, DateTime> _stamps = {};

  String _key(ProjectRoot root, String path) => '${root.persistedKey}|$path';

  void record(ProjectRoot root, String path, DateTime? modified) {
    if (modified == null) {
      _stamps.remove(_key(root, path));
    } else {
      _stamps[_key(root, path)] = modified;
    }
  }

  DateTime? of(ProjectRoot root, String path) => _stamps[_key(root, path)];

  void forget(ProjectRoot root, String path) => _stamps.remove(_key(root, path));
}
