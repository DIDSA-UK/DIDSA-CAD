import 'package:flutter/material.dart';

import 'action_sheet.dart';

/// Assembly support Phase 3b (`docs/assembly-scope.md` §3): the actions
/// Phase 4's Component context menu will offer for a single selected
/// Occurrence - Make Focus/Exit Focus (wiring `AssemblyFocusStack.push`/
/// `pop` for the first time), Move/Rotate (Phase 5's gizmo), Hide/Show,
/// Isolate, Mate (Phase 6), and Pattern (Phase 7). Built now, alongside the
/// Assembly-lens "Add" FAB menu (`add_button_menu.dart`'s
/// [AssemblyAddMenuAction]), since both are the same flat bottom-sheet-
/// action-list shape and share two entries (Mate/Pattern) - see
/// [showComponentContextMenu]'s own doc comment for why this file exists
/// ahead of the phase that actually wires it up.
enum ComponentContextMenuAction {
  makeFocus,
  exitFocus,
  moveRotate,
  hide,
  show,
  isolate,
  mate,
  pattern,
  fix,
  float,
  rename,
  delete,
}

/// Shows the Component context menu for one Occurrence -
/// `AssemblyTreePanel.onOccurrenceLongPress`'s eventual real action (Phase
/// 4; today that callback only selects the row - see its own doc comment
/// in `part_screen.dart`). Not wired to that call site yet: Make Focus/
/// Exit Focus need `SelectionFilterState`'s new `component` kind and the
/// opacity/selectability split Phase 4 builds first (`docs/assembly-
/// scope.md` §3), so this function exists and is directly tested on its
/// own, but has no caller in `part_screen.dart` until that phase lands -
/// the same "build the shared shell now, wire the call site later" split
/// this phase applies to [AssemblyAddMenuAction] above.
///
/// [isFocused] picks Make Focus vs Exit Focus (a Part already focused
/// shows "Exit Focus" instead, mirroring `AssemblyFocusStack.isFocused`);
/// [hidden] picks Hide vs Show, the same "label names the next state"
/// convention `PartToolbar`'s own Hide/Show Reference Planes entry uses.
/// Pattern is enabled too (Phase 7, `docs/assembly-scope.md` §2j) - its own
/// handler opens `PatternPanel` targeting whichever Occurrence was
/// long-pressed as the pattern's own (single) source, mirroring how Mate's
/// entry opens its own authoring flow.
/// Move/Rotate is enabled - found disabled during a post-Phase-5
/// completeness audit (`docs/assembly-scope.md` appendix item 5) even
/// though Phase 5's gizmo already works via plain tap-selection, entirely
/// independent of this menu entry: `part_screen.dart`'s
/// `_onOccurrenceLongPress` already selects the long-pressed row (setting
/// `_selectedOccurrenceId`, exactly what `_gizmoTargetOccurrence` reads)
/// before this menu even opens, so enabling the entry needed no new
/// handling of its own. Mate is enabled too (Phase 6's mate solver) - its
/// own handler opens the same generic 2-entity picking flow the "Add"
/// FAB's own Add Mate entry does.
Future<ComponentContextMenuAction?> showComponentContextMenu(
  BuildContext context, {
  required bool isFocused,
  required bool hidden,
  required bool fixed,
}) {
  return showActionSheet<ComponentContextMenuAction>(context, [
    ActionSheetEntry(
      action: isFocused ? ComponentContextMenuAction.exitFocus : ComponentContextMenuAction.makeFocus,
      label: isFocused ? 'Exit Focus' : 'Make Focus',
      icon: isFocused ? Icons.output_outlined : Icons.center_focus_strong_outlined,
    ),
    ActionSheetEntry(
      action: ComponentContextMenuAction.moveRotate,
      label: 'Move/Rotate',
      icon: Icons.open_with,
      // A `fixed` Occurrence's own gizmo never shows (`_gizmoTargetOccurrence`'s
      // own doc comment) and the backend rejects a transform PATCH against
      // one outright (`occurrence_is_fixed`) - disabling this entry up front
      // avoids offering an action that would silently do nothing (no gizmo
      // ever appears) or surface a raw server error either way.
      enabled: !fixed,
      disabledReason: fixed ? 'Float this component first' : null,
    ),
    ActionSheetEntry(
      action: hidden ? ComponentContextMenuAction.show : ComponentContextMenuAction.hide,
      label: hidden ? 'Show' : 'Hide',
      icon: hidden ? Icons.visibility_outlined : Icons.visibility_off_outlined,
    ),
    const ActionSheetEntry(
      action: ComponentContextMenuAction.isolate,
      label: 'Isolate',
      icon: Icons.filter_center_focus,
    ),
    // Bug report (assembly testing): "I can't find a method of applying a
    // fix on a part" - a "Fix" constraint (mirrors real CAD's own fixed/
    // grounded-component convention), same "label names the next state"
    // convention Hide/Show above already uses. Backed by `Occurrence.fixed`
    // (`update_occurrence_transform`'s own `fixed` field) - locks this
    // Occurrence's transform against the gizmo and any Mate solve
    // targeting it (see that endpoint's own `occurrence_is_fixed` 422).
    ActionSheetEntry(
      action: fixed ? ComponentContextMenuAction.float : ComponentContextMenuAction.fix,
      label: fixed ? 'Float' : 'Fix',
      icon: fixed ? Icons.push_pin : Icons.push_pin_outlined,
    ),
    const ActionSheetEntry(
      action: ComponentContextMenuAction.mate,
      label: 'Mate',
      icon: Icons.link,
    ),
    const ActionSheetEntry(
      action: ComponentContextMenuAction.pattern,
      label: 'Pattern',
      icon: Icons.grid_view_outlined,
    ),
    // Save/project overhaul Phase 2 (`docs/save-project-overhaul-scope.md`
    // §3.2): the correction path for Create Component's own auto-generated
    // "Component N" default - `part_screen.dart`'s own handler renames the
    // Occurrence's display name always, and (when this Part is only
    // instanced once in the current session) the underlying Part's own
    // name and on-disk file too.
    const ActionSheetEntry(
      action: ComponentContextMenuAction.rename,
      label: 'Rename',
      icon: Icons.drive_file_rename_outline,
    ),
    // Assembly-audit gap `[27]` (`docs/assembly-scope.md`): no way to remove
    // a placed component from an assembly had ever been built - full CRUD
    // existed for Mates/ComponentPatterns but only ever PATCH for an
    // Occurrence itself. `part_screen.dart`'s own handler warns first
    // (naming any Mate/ComponentPattern that would cascade-delete along
    // with it) before actually calling `DocumentApiClient.deleteOccurrence`.
    const ActionSheetEntry(
      action: ComponentContextMenuAction.delete,
      label: 'Delete',
      icon: Icons.delete_outline,
    ),
  ]);
}
