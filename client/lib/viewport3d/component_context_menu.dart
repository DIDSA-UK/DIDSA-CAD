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
/// Move/Rotate/Mate/Pattern have no backing implementation yet (Phases
/// 5-7) and render disabled, same "ship the stable shape, not the gap" rule
/// [showAssemblyAddMenu] already applies to its own Mate/Pattern rows.
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
    ActionSheetEntry(
      action: ComponentContextMenuAction.moveRotate,
      label: 'Move/Rotate',
      icon: Icons.open_with,
      enabled: false,
      disabledReason: 'Coming soon - needs Phase 5\'s move/rotate gizmo',
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
      enabled: false,
      disabledReason: 'Coming soon - needs Phase 6\'s mate solver',
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
