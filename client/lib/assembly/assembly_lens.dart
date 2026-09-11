/// Which tool set and side panel are shown for the currently-focused Part
/// (see `AssemblyFocusStack.current`) - a pure UI-only lens over the *same*
/// open `.didsa` file and the *same* 3D viewport content
/// (`docs/assembly-scope.md`'s "lens toggle" decision: switching lens never
/// navigates to a different screen, never changes the viewport's camera or
/// rendered geometry, and never re-fetches anything - only the side panel
/// and toolbar swap).
///
/// [part] shows `FeatureTreePanel` and the existing feature toolbar (today's
/// unchanged single-part experience). [assembly] shows `AssemblyTreePanel`
/// and an Assembly-mode toolbar (insert/create component, mate, pattern -
/// Phases 3-7). A Part with no occurrences/mates at all can still be viewed
/// in [assembly] lens (an empty tree, per `AssemblyTreePanel`'s own
/// empty-state) - there is no "this file isn't an assembly" gate, matching
/// the model-correction decision that any Part may hold occurrences/mates
/// alongside its features.
enum AssemblyLens { part, assembly }
