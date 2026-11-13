/// A storage service that can say which file holds a Part id without reading the files: a server project's store keeps an index of
/// every native file's root Part id (`GET .../parts/{part_id}`, and the `part_id` of every file in the tree), so the moved-files rule
/// (`docs/moved-files-scope.md`) asks the store instead of reading every file. Local folders have no such index: the methods answer
/// null and `ProjectFileIndex` reads the files as it always did.
library;

import 'project_root.dart';

abstract interface class PartIdIndex {
  /// Whether [root] has such an index (a server project does; a local folder does not).
  bool hasPartIndex(ProjectRoot root);

  /// The root Part id of the file at [path], from the index (null: no such file, or not a native file).
  Future<String?> partIdAt(ProjectRoot root, String path);

  /// Every file of [root] with its root Part id (null when the file is not a native file), or null when [root] has no index.
  Future<List<({String path, String? partId})>?> indexEntries(ProjectRoot root);

  /// The paths whose root Part id is [partId], or null when [root] has no index (an unknown id is an empty list, not null).
  Future<List<String>?> pathsWithPartId(ProjectRoot root, String partId);
}
