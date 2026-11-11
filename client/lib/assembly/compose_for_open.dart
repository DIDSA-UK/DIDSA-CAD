import '../storage/project_root.dart';
import 'assembly_document_client.dart';
import 'assembly_graph_composer.dart';
import 'folder_match_dialog.dart';
import 'folder_match_session_choice.dart';
import 'reference_report.dart';

/// The Open flow's compose step (Flutter-testing feedback 2026-11-11, item 1b, Decision 1): composes [relativePath], and when
/// references with no stored id turn up whose files moved with the project folder ([ReferenceOutcome.likely]) asks the user
/// through [ask] **before anything is imported**, unless [choice] already holds this session's answer.
///
/// * the session answer is "use them": the compose accepts them straight away, no question;
/// * the session answer is "not now": no question, they stay suggestions;
/// * no answer yet: [ask]; "Use them" re-composes with `acceptLikely: true` (the file index is cached, so the second pass does
///   not walk the folder again, and it also accepts the likely matches found below the first ones); "Not now" (or a dismissed
///   dialog) keeps the first compose, its likely references going to the banner and the Review sheet as suggestions.
///   "Don't ask again this session" stores the answer in [choice] (memory only).
///
/// The caller imports the returned graph ([AssemblyDocumentClient.importComposed]) - once.
Future<ComposedAssemblyGraph> composeForOpen(
  AssemblyDocumentClient client,
  ProjectRoot root,
  String relativePath, {
  required Future<FolderMatchAnswer?> Function(List<ReferenceReport> likely) ask,
  FolderMatchSessionChoice? choice,
  void Function()? onSearching,
}) async {
  final session = choice ?? FolderMatchSessionChoice.instance;
  var composed = await client.composeGraph(root, relativePath, acceptLikely: session.answer == true, onSearching: onSearching);
  final likely = composed.references.where((r) => r.outcome == ReferenceOutcome.likely).toList();
  if (likely.isEmpty || session.answer != null) return composed;
  final answer = await ask(likely);
  if (answer == null) return composed;
  if (answer.dontAskAgain) session.remember(answer.useThem);
  if (answer.useThem) {
    composed = await client.composeGraph(root, relativePath, acceptLikely: true, onSearching: onSearching);
  }
  return composed;
}
