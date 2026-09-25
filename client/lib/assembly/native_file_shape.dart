/// Save/project overhaul Phase 6 (`docs/save-project-overhaul-scope.md`
/// §5, Phase 6): the unified Open entry's own "which reader does this file
/// actually need" check - promoted to a free, pure function (rather than a
/// private `_PartScreenState` method) so it's directly, cheaply unit-
/// testable on its own, the same reasoning `relative_path.dart`'s own
/// free functions already follow for this codebase's pure/no-`dart:io`
/// helpers.
library;

/// Whether `decoded` (an already-parsed `.DIDSAprt` file's own top-level
/// JSON) is shaped like a legacy whole-session Bundle - more than one Part
/// embedded in the same file - rather than a Project's own one-Part-per-
/// file shape `AssemblyGraphComposer.compose` expects. Mirrors that
/// method's own `parts.length != 1` check exactly (it throws a
/// `FormatException` for this same condition), just queried ahead of time
/// here so `PartScreen._onOpenPressed` can route to the right reader
/// instead of trying one and catching the other's failure.
bool isBundleShapedNativeFile(Map<String, dynamic> decoded) {
  final parts = ((decoded['document'] as Map?)?['parts'] as List?) ?? const [];
  return parts.length > 1;
}
