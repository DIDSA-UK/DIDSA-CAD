import 'project_root.dart';
import 'storage_service.dart';

/// AI Modelling multi-part/assembly overhaul, Phase C
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the "already
/// have one, else last-used, else prompt" resolution
/// `PartScreen._ensureProjectRoot` established first (Phase 15), factored
/// out here so a caller with no `State` of its own (`ToolChooserScreen`'s
/// stateless "AI Modelling" tile) can reuse the exact same fallback order
/// without duplicating it. `PartScreen._ensureProjectRoot` keeps its own
/// copy (it additionally caches the result on `State`, which this bare
/// function has nowhere to do) - both agree on the same three-step order.
///
/// A user cancelling the picker is a silent no-op (`null`), never a
/// surfaced error - matches `StorageService.pickOrCreateProjectRoot`'s own
/// cancel convention and every other caller of it in this app.
Future<ProjectRoot?> ensureProjectRoot(StorageService storageService, {ProjectRoot? current}) async {
  if (current != null) return current;
  final lastUsed = await storageService.lastUsedProjectRoot();
  if (lastUsed != null) return lastUsed;
  try {
    return await storageService.pickOrCreateProjectRoot();
  } on StorageException {
    return null;
  }
}
