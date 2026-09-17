import '../viewport3d/override_stack.dart';

/// Which Part is currently primary within a composed assembly - the
/// primary Part is what [AssemblyLens.part] edits, what
/// `AssemblyTreePanel`/`FeatureTreePanel` both target, and (Phase 4) the one
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

  AssemblyFocusStack(this.rootPartId);

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
    _overrides.push(partId);
    _occurrencePath = [..._occurrencePath, occurrenceId];
    _labelPath = [..._labelPath, displayName];
  }

  /// Un-focuses back to whatever was focused before, or [rootPartId] if this
  /// was the last focus pushed. A no-op (returns null) if already at root.
  String? pop() {
    if (_occurrencePath.isNotEmpty) {
      _occurrencePath = _occurrencePath.sublist(0, _occurrencePath.length - 1);
    }
    if (_labelPath.isNotEmpty) {
      _labelPath = _labelPath.sublist(0, _labelPath.length - 1);
    }
    return _overrides.pop();
  }

  /// Un-focuses all the way back to [rootPartId] in one step - e.g. closing
  /// the assembly file or opening a different one.
  void clear() {
    _overrides.clear();
    _occurrencePath = const [];
    _labelPath = const [];
  }
}
