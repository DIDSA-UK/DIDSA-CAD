import 'package:flutter/material.dart';

import 'assembly_lens.dart';

/// Assembly support Phase 3b (`docs/assembly-scope.md` §3): the one accent
/// color used everywhere a lens-specific visual signal is needed - the FAB
/// row, `PartToolbar`'s own chrome, and `AssemblyTreePanel`'s header. Closes
/// the other half of the gap Phase 3 left open (alongside the "Add"
/// FAB/`PartToolbar` toolset in `add_button_menu.dart`/
/// `component_context_menu.dart`): nothing in the UI signalled which lens
/// was active beyond the tree panel's own content, so switching lens was
/// easy to miss on-device.
///
/// [AssemblyLens.assembly] resolves to [ColorScheme.tertiary] - Material
/// 3's own dedicated "a distinct but still theme-harmonious accent" slot,
/// rather than a hand-picked hex value that would need its own separate
/// light/dark tuning; [AssemblyLens.part] reverts to [ColorScheme.primary],
/// the app's existing default accent (the color `FloatingActionButton`/etc.
/// already use with no override), so Part lens looks exactly as it always
/// has. Takes a [ColorScheme] directly (not a [BuildContext]) so it stays a
/// pure function - directly unit-testable against a specific light/dark
/// [ColorScheme] with no widget tree needed, and easy to call from a
/// widget's own `build` via `Theme.of(context).colorScheme`.
Color assemblyLensAccentColor(ColorScheme colorScheme, AssemblyLens lens) {
  return lens == AssemblyLens.assembly ? colorScheme.tertiary : colorScheme.primary;
}

/// The container/on-container pair for [assemblyLensAccentColor] - used for
/// a filled/tinted background (`AssemblyTreePanel`'s header) rather than a
/// foreground/icon color, so text drawn on top of it stays legible in both
/// light and dark themes. [AssemblyLens.assembly] resolves to
/// [ColorScheme.tertiaryContainer]/[ColorScheme.onTertiaryContainer];
/// [AssemblyLens.part] resolves to [ColorScheme.surface]/
/// [ColorScheme.onSurface] - a neutral background, not tinted at all,
/// matching how `FeatureTreePanel`'s own header looks today.
(Color background, Color onBackground) assemblyLensContainerColors(
  ColorScheme colorScheme,
  AssemblyLens lens,
) {
  return lens == AssemblyLens.assembly
      ? (colorScheme.tertiaryContainer, colorScheme.onTertiaryContainer)
      : (colorScheme.surface, colorScheme.onSurface);
}

/// The background/foreground pair for a lens-tinted *button* (the small
/// FABs in the top-left column: hamburger/feature-tree/lens-toggle) -
/// Assembly lens's own [ColorScheme.tertiaryContainer]/
/// [ColorScheme.onTertiaryContainer]. Bug report (assembly testing):
/// [assemblyLensAccentColor]'s bare [ColorScheme.tertiary] read as a much
/// darker/more saturated red than Part lens's own buttons (which use
/// `FloatingActionButton`'s M3 default of [ColorScheme.primaryContainer]/
/// [ColorScheme.onPrimaryContainer] - a light "container" tone, not the
/// fully-saturated [ColorScheme.primary] tone). This pairs
/// `tertiaryContainer` with `onTertiaryContainer` for the same lighter
/// tonal weight *and* keeps the icon legible on it (an explicit
/// foreground is needed here - unlike Part lens's `null`/`null`, where
/// `FloatingActionButton` already supplies a matching default pair on its
/// own, an explicit `backgroundColor` with no matching `foregroundColor`
/// would otherwise still default to `onPrimaryContainer`, not
/// `onTertiaryContainer`). Callers only apply this pair while
/// `lens == AssemblyLens.assembly`; Part lens keeps passing `null` to both
/// params so `FloatingActionButton` keeps its own default look untouched.
(Color background, Color onBackground) assemblyLensButtonColors(ColorScheme colorScheme) {
  return (colorScheme.tertiaryContainer, colorScheme.onTertiaryContainer);
}
