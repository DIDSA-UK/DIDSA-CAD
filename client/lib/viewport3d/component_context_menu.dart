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
/// Pattern has no backing implementation yet (Phase 7) and renders
/// disabled, same "ship the stable shape, not the gap" rule
/// [showAssemblyAddMenu] already applies to its own Pattern row.
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
}) {
  return showActionSheet<ComponentContextMenuAction>(context, [
    ActionSheetEntry(
      action: isFocused ? ComponentContextMenuAction.exitFocus : ComponentContextMenuAction.makeFocus,
      label: isFocused ? 'Exit Focus' : 'Make Focus',
      icon: isFocused ? Icons.output_outlined : Icons.center_focus_strong_outlined,
    ),
    const ActionSheetEntry(
      action: ComponentContextMenuAction.moveRotate,
      label: 'Move/Rotate',
      icon: Icons.open_with,
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
    const ActionSheetEntry(
      action: ComponentContextMenuAction.mate,
      label: 'Mate',
      icon: Icons.link,
    ),
    const ActionSheetEntry(
      action: ComponentContextMenuAction.pattern,
      label: 'Pattern',
      icon: Icons.grid_view_outlined,
      enabled: false,
      disabledReason: 'Coming soon - needs Phase 7\'s component pattern',
    ),
  ]);
}
