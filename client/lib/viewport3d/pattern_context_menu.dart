import 'package:material_ui/material_ui.dart';

import 'action_sheet.dart';

/// The actions offered on a Patterns row of the Assembly tree (long-press on touch, right click on desktop - the same entries).
/// `docs/pattern-followers-and-dissolve-plan.md` F2: Dissolve turns every copy into a real component.
enum PatternContextMenuAction { edit, dissolve, delete }

/// [at] shows it as a popup at a right click (desktop), else the bottom sheet. Dissolve is disabled for a suppressed pattern (it has
/// no live copies to turn into components).
Future<PatternContextMenuAction?> showPatternContextMenu(BuildContext context, {required bool suppressed, Offset? at}) {
  return showContextMenu<PatternContextMenuAction>(context, at: at, [
    const ActionSheetEntry(action: PatternContextMenuAction.edit, label: 'Edit', icon: Icons.edit_outlined),
    ActionSheetEntry(
      action: PatternContextMenuAction.dissolve,
      label: 'Dissolve',
      icon: Icons.scatter_plot_outlined,
      enabled: !suppressed,
      disabledReason: suppressed ? 'Suppressed - no copies to dissolve' : null,
    ),
    const ActionSheetEntry(action: PatternContextMenuAction.delete, label: 'Delete', icon: Icons.delete_outline),
  ]);
}
