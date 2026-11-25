import '../viewport3d/override_stack.dart';

/// Which Part is currently primary within a composed assembly - the
/// primary Part is what [AssemblyLens.part] edits, what
/// `AssemblyTreePanel`/the build tree both target, and (Phase 4) the one
/// whose own instance renders fully opaque while its peers/parents go
/// translucent. "Make Focus" (Phase 4) pushes; "Exit Focus" pops.
///
/// Reuses `OverrideStack<String>` one level higher than its first user
/// (`PartScreen`'s `SelectionFilterState` overrides) - same "push a
/// temporary override, pop restores whatever was active before" primitive,
/// just tracking a focused Part id instead of a selection filter. [rootPartId]
/// is the permanent base case: it is never itself pushed onto the
/// `OverrideStack`, so it can't be popped away - there is always a focused
/// Part for as long as an assembly is open, which is what makes [current]
/// non-nullable (unlike `OverrideStack.current`, nullable because it has no
/// base case of its own).
class AssemblyFocusStack {
  final String rootPartId;
  final OverrideStack<String> _overrides = OverrideStack<String>();

  /// Phase 4 fix (`docs/assembly-scope.md` §5 appendix item 4): the full
  /// chain of Occurrence ids from the true root down to the currently-
  /// focused Occurrence - `const []` while unfocused. [push]/[pop]/[clear]
  /// are the only things that ever reassign this - a bare read of
  /// [currentOccurrencePath] always returns the exact same `List` instance
  /// until the next mutating call, the same "stable identity until content
  /// actually changes" contract `PartViewport.bodies`'s own doc comment
  /// already establishes for this codebase's change-detection convention
  /// (`didUpdateWidget`'s `!=` checks are identity-based for a `List`,
  /// never a deep-equality one).
  List<String> _occurrencePath = const [];

  /// Bug fix: the display name shown for each [push] onto [_occurrencePath],
  /// same "parallel stack" shape as [_occurrencePath] itself. Lets
  /// `AssemblyTreePanel` show a breadcrumb naming whichever Part is
  /// currently focused - previously there was no client-side record of it
  /// at all once [_refreshAssemblyTree] re-fetched (a focused Part with no
  /// Occurrences of its own renders an empty tree with nothing to long-press
  /// "Exit Focus" on, leaving the user stuck with no visible way back out -
  /// see `AssemblyTreePanel`'s own breadcrumb row for the other half of this
  /// fix).
  List<String> _labelPath = const [];

  /// The Part id pushed with each level of [_occurrencePath] (parallel to it).
  List<String> _partPath = const [];

  AssemblyFocusStack(this.rootPartId);

  /// Counts every change of the focus ([push], [pop], [clear]; [setLevels] through them). C3: an action that waits for the focused Part's
  /// content compares it, so a focus that moved away and back meanwhile still counts as a change.
  int get revision => _revision;
  int _revision = 0;

  /// B3: the display name of every focused level, the outermost first (the breadcrumb strip's crumbs after the root's).
  List<String> get labelPath => _labelPath;

  /// B3: every focused level as (Part id, occurrence id, label), the outermost first: what [setLevels] takes back.
  List<(String, String, String)> get levels => [
        for (var i = 0; i < _occurrencePath.length; i++) (_partPath[i], _occurrencePath[i], _labelPath[i]),
      ];

  /// B3: makes the focus exactly [target]: pops the levels that are not a prefix of it (by occurrence id), then pushes the rest. "Focus
  /// here" on a row in another branch, a crumb of the strip, and Edit Alone's way back all go through this.
  void setLevels(List<(String, String, String)> target) {
    var keep = 0;
    while (keep < target.length && keep < _occurrencePath.length && _occurrencePath[keep] == target[keep].$2) {
      keep++;
    }
    while (depth > keep) {
      pop();
    }
    for (var i = keep; i < target.length; i++) {
      push(target[i].$1, target[i].$2, target[i].$3);
    }
  }

  /// The currently-focused Part id - [rootPartId] until something is pushed.
  String get current => _overrides.current ?? rootPartId;

  /// True once at least one focus has been pushed past [rootPartId].
  bool get isFocused => _overrides.isActive;

  /// How many focus levels deep past [rootPartId] - 0 at the root.
  int get depth => _overrides.depth;

  /// See [_occurrencePath]'s own doc comment.
  List<String> get currentOccurrencePath => _occurrencePath;

  /// The display name of whichever Part is currently focused - `null` while
  /// unfocused (at [rootPartId]), else [_labelPath]'s last entry.
  String? get currentLabel => _labelPath.isEmpty ? null : _labelPath.last;

  /// Focuses [partId] via the Occurrence identified by [occurrenceId] - e.g.
  /// "Make Focus" on a Component context menu (Phase 4). [occurrenceId] is
  /// appended to [currentOccurrencePath] (not replacing it) so a focus
  /// pushed while already focused several levels deep still records the
  /// *whole* chain down to it, not just this one step. [displayName] is
  /// whatever the focused Occurrence was labelled at focus time (e.g.
  /// `occurrenceDisplayName`'s own result) - purely for [currentLabel]'s own
  /// breadcrumb display, never resolved again after this call.
  void push(String partId, String occurrenceId, String displayName) {
    _revision++;
    _overrides.push(partId);
    _occurrencePath = [..._occurrencePath, occurrenceId];
    _labelPath = [..._labelPath, displayName];
    _partPath = [..._partPath, partId];
  }

  /// Un-focuses back to whatever was focused before, or [rootPartId] if this
  /// was the last focus pushed. A no-op (returns null) if already at root.
  String? pop() {
    _revision++;
    if (_occurrencePath.isNotEmpty) {
      _occurrencePath = _occurrencePath.sublist(0, _occurrencePath.length - 1);
    }
    if (_labelPath.isNotEmpty) {
      _labelPath = _labelPath.sublist(0, _labelPath.length - 1);
    }
    if (_partPath.isNotEmpty) {
      _partPath = _partPath.sublist(0, _partPath.length - 1);
    }
    return _overrides.pop();
  }

  /// Un-focuses all the way back to [rootPartId] in one step - e.g. closing
  /// the assembly file or opening a different one.
  void clear() {
    _revision++;
    _overrides.clear();
    _occurrencePath = const [];
    _labelPath = const [];
    _partPath = const [];
  }
}
