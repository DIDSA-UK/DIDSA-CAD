/// Which tree a [TreeMultiSelectController] session was entered from - the
/// Build Tree (Bodies/Surfaces/Planes/Features rows) or the Assembly Tree
/// (Occurrence rows). A session never mixes the two: entering one exits the
/// other (see `PartScreen._exitAllPickerAndSelectModes`).
enum TreeMultiSelectScope { buildTree, assemblyTree }

/// Selection-key encoding for the Build Tree's multi-select session. A
/// single-body Feature's Body id is the very same string as its Feature id
/// (see `body_naming.dart`'s `baseFeatureId`), so a bare id alone can't say
/// whether a Body row or a Feature row was selected - every key is prefixed
/// with its row kind instead. The Assembly Tree only ever selects
/// Occurrences, so its keys are the bare Occurrence ids (no prefix needed).
abstract final class TreeMultiSelectKeys {
  static const String _featurePrefix = 'feature:';
  static const String _bodyPrefix = 'body:';
  static const String _surfacePrefix = 'surface:';

  static String feature(String featureId) => '$_featurePrefix$featureId';
  static String body(String bodyId) => '$_bodyPrefix$bodyId';
  static String surface(String surfaceId) => '$_surfacePrefix$surfaceId';

  /// The Feature id [key] names, or `null` if [key] isn't a Feature key.
  static String? featureIdOf(String key) =>
      key.startsWith(_featurePrefix) ? key.substring(_featurePrefix.length) : null;

  /// The Body id [key] names, or `null` if [key] isn't a Body key.
  static String? bodyIdOf(String key) => key.startsWith(_bodyPrefix) ? key.substring(_bodyPrefix.length) : null;

  /// The Surface id [key] names, or `null` if [key] isn't a Surface key.
  static String? surfaceIdOf(String key) =>
      key.startsWith(_surfacePrefix) ? key.substring(_surfacePrefix.length) : null;
}

/// Plain-Dart state holder for a tree's long-press multi-select session -
/// no listeners of its own, [PartScreen] owns it and wraps every mutation in
/// its own `setState` exactly like every other piece of state in that
/// screen. Mirrors `OverrideStack`'s "small standalone state class in its
/// own file" convention.
///
/// [toggle] leaving the selection empty also ends the session - an empty
/// multi-select has nothing to act on, so it exits rather than lingering
/// as an invisible mode that would keep swallowing row taps.
class TreeMultiSelectController {
  TreeMultiSelectController(this.scope);

  final TreeMultiSelectScope scope;

  final Set<String> selectedIds = <String>{};
  bool _active = false;

  bool get active => _active;
  int get count => selectedIds.length;
  bool contains(String id) => selectedIds.contains(id);

  /// Starts a session with [id] as its only member.
  void enter(String id) {
    _active = true;
    selectedIds
      ..clear()
      ..add(id);
  }

  /// Ends the session and drops the selection.
  void exit() {
    _active = false;
    selectedIds.clear();
  }

  /// Toggles [id]'s membership - a no-op outside an active session. Ends
  /// the session if that leaves the selection empty.
  void toggle(String id) {
    if (!_active) return;
    if (!selectedIds.remove(id)) selectedIds.add(id);
    if (selectedIds.isEmpty) _active = false;
  }

  /// Drops every member without ending the session.
  void clear() => selectedIds.clear();
}
