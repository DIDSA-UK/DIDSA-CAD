import '../viewport3d/override_stack.dart';

/// Which Part is currently primary within a composed assembly - the
/// primary Part is what [AssemblyLens.part] edits, what
/// `AssemblyTreePanel`/`FeatureTreePanel` both target, and (once Phase 4's
/// opacity tiers land) the one rendered fully opaque while its peers/parents
/// go translucent. "Make Focus" (Phase 6) pushes; the exit/back action pops.
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

  AssemblyFocusStack(this.rootPartId);

  /// The currently-focused Part id - [rootPartId] until something is pushed.
  String get current => _overrides.current ?? rootPartId;

  /// True once at least one focus has been pushed past [rootPartId].
  bool get isFocused => _overrides.isActive;

  /// How many focus levels deep past [rootPartId] - 0 at the root.
  int get depth => _overrides.depth;

  /// Focuses [partId] - e.g. "Make Focus" on a Component context menu
  /// (Phase 4/6).
  void push(String partId) => _overrides.push(partId);

  /// Un-focuses back to whatever was focused before, or [rootPartId] if this
  /// was the last focus pushed. A no-op (returns null) if already at root.
  String? pop() => _overrides.pop();

  /// Un-focuses all the way back to [rootPartId] in one step - e.g. closing
  /// the assembly file or opening a different one.
  void clear() => _overrides.clear();
}
