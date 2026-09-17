import 'package:flutter/material.dart';

import 'action_sheet.dart';

/// Test report item 6: the actions offered when long-pressing a Mate row in
/// [AssemblyTreePanel]'s Mates section - mirrors `component_context_menu.
/// dart`'s [ComponentContextMenuAction]/[showComponentContextMenu] shape
/// exactly (same shared [showActionSheet] shell), just for the much smaller
/// two-action Mate case.
enum MateContextMenuAction { edit, delete }

/// Shows the Mate context menu - `AssemblyTreePanel.onMateLongPress`'s real
/// call site (`part_screen.dart`'s `_onMateLongPress`). Edit opens a small
/// dialog to revise `value`/`flipped` (and, for a `concentric` Mate, `allow
/// Rotation` - `docs/assembly-scope.md`'s "Allow rotation" checkbox) via
/// `DocumentApiClient.updateMate` - never `type`/`references`, mirroring
/// that endpoint's own narrow mutation surface (a Mate's geometry is fixed
/// at creation; only its parameters are ever revised in place). Delete
/// confirms, then calls `DocumentApiClient.deleteMate`, the same "ask
/// first" precedent `_confirmDeleteComponentPattern` already establishes
/// for a Pattern row's own long-press.
Future<MateContextMenuAction?> showMateContextMenu(BuildContext context) {
  return showActionSheet<MateContextMenuAction>(context, [
    const ActionSheetEntry(
      action: MateContextMenuAction.edit,
      label: 'Edit',
      icon: Icons.edit_outlined,
    ),
    const ActionSheetEntry(
      action: MateContextMenuAction.delete,
      label: 'Delete',
      icon: Icons.delete_outline,
    ),
  ]);
}
