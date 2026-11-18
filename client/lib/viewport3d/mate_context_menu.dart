import 'package:material_ui/material_ui.dart';

import 'action_sheet.dart';
import 'mate_reference_state.dart';
import '../api/document_api_client.dart' show MateDto;

/// Test report item 6: the actions offered when long-pressing a Mate row in
/// [AssemblyTreePanel]'s Mates section - mirrors `component_context_menu.
/// dart`'s [ComponentContextMenuAction]/[showComponentContextMenu] shape
/// exactly (same shared [showActionSheet] shell), just for the much smaller
/// two-action Mate case.
///
/// N1d: [confirmReferences] (a held mate: accept the face it is now bound to) and [gotIt] (a followed mate: dismiss the note the
/// backend only says once) are offered first, and only for a mate the backend flagged; see `mate_reference_state.dart`.
enum MateContextMenuAction { edit, delete, confirmReferences, gotIt }

/// Desktop input D4: [at] shows it as a popup at a right click.
///
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
Future<MateContextMenuAction?> showMateContextMenu(BuildContext context, {Offset? at, MateDto? mate}) {
  return showContextMenu<MateContextMenuAction>(context, at: at, [
    if (mate != null && mateOffersConfirm(mate))
      const ActionSheetEntry(
        action: MateContextMenuAction.confirmReferences,
        label: 'Confirm',
        icon: Icons.check_circle_outline,
      ),
    if (mate != null && mateOffersGotIt(mate))
      const ActionSheetEntry(
        action: MateContextMenuAction.gotIt,
        label: 'Got it',
        icon: Icons.done,
      ),
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
