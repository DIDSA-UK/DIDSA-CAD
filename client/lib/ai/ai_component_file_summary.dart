import '../assembly/relative_path.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';

/// Assembly support Phase 18 (`docs/assembly-scope.md` §6 `[2]`): the
/// prompt-facing "which project files can add_component insert" summary -
/// `ai_existing_part_summary.dart`'s own sibling, one level down (files on
/// disk rather than already-built Features/Occurrences). Embedded into
/// `ai_scoping_prompt.dart`'s own locked "Available Component Files" block.
///
/// **Deliberately does not** try to exclude the currently-open Part's own
/// file or already-inserted components - there is no reliable way to know
/// "the current Part's own relative path" (it may be unsaved, or loaded via
/// multi-file compose with no single canonical path), and re-inserting an
/// already-placed file for a legitimate second Occurrence is *supported*
/// behavior (`mergeComponentIntoDocument`'s own dedup-by-Part-id
/// convention), not an error to filter out. The one real error case
/// (inserting a Part into itself) already fails clearly at execution time
/// through `AddComponentException` - this summary just warns the LLM about
/// that failure mode in `ai_scoping_prompt.dart`'s own locked text rather
/// than heuristically pre-filtering here.
///
/// `''` (empty) when nothing is available (no project root, an unreachable
/// one, or a project with no native files in it at all) - matching
/// `summarizeExistingOccurrencesForPrompt`'s own "no section appended"
/// convention.
Future<String> summarizeAvailableComponentFilesForPrompt(
  StorageService storageService,
  ProjectRoot projectRoot, {
  int maxEntries = 30,
}) async {
  List<String> paths;
  try {
    paths = await storageService.listFiles(projectRoot, extensionFilter: kNativeFileExtension);
  } on StorageException {
    return '';
  }
  if (paths.isEmpty) return '';
  paths.sort();
  final shown = paths.take(maxEntries).toList();
  final lines = [for (var i = 0; i < shown.length; i++) '${i + 1}. ${shown[i]}'];
  if (paths.length > maxEntries) {
    lines.add('...and ${paths.length - maxEntries} more file(s) not shown.');
  }
  return lines.join('\n');
}
