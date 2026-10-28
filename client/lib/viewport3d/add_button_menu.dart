import 'package:flutter/material.dart';

import 'action_sheet.dart';
import 'svg_icon.dart';

/// Actions available from the floating "Add" button's flyout. Stage 10b adds
/// [newSketch]; Stage 19b Item 3 adds [feature] (opens the second-level
/// Feature picker - see [showFeaturePickerSheet]) alongside it.
enum AddButtonMenuAction { newSketch, feature }

/// Shows a bottom sheet of actions for the "Add" FAB, replacing its old
/// direct-to-`_addSketchFeature` behaviour - per the Stage 10b brief, the FAB
/// should open a flyout rather than act directly. Part-lens only - see
/// [showAssemblyAddMenu] for the Assembly-lens counterpart this FAB shows
/// instead when `PartScreen._lens == AssemblyLens.assembly`
/// (`docs/assembly-scope.md` §3's Phase 3b).
Future<AddButtonMenuAction?> showAddButtonMenu(BuildContext context, {Offset? at}) {
  // Desktop input D4: the same two rows, as a popup at [at] for a mouse.
  if (at != null) {
    return showContextMenu<AddButtonMenuAction>(context, at: at, const [
      ActionSheetEntry(
        action: AddButtonMenuAction.newSketch,
        label: 'New Sketch',
        leading: SvgIcon('assets/icons/feature/feature_new_sketch.svg'),
      ),
      ActionSheetEntry(
        action: AddButtonMenuAction.feature,
        label: 'Feature',
        leading: SvgIcon('assets/icons/feature/feature_tree.svg'),
      ),
    ]);
  }
  return showModalBottomSheet<AddButtonMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_new_sketch.svg'),
            title: const Text('New Sketch'),
            onTap: () => Navigator.of(context).pop(AddButtonMenuAction.newSketch),
          ),
          ListTile(
            leading: const SvgIcon('assets/icons/feature/feature_tree.svg'),
            title: const Text('Feature'),
            onTap: () => Navigator.of(context).pop(AddButtonMenuAction.feature),
          ),
        ],
      ),
    ),
  );
}

/// Actions available from the "Add" FAB's flyout while in Assembly lens
/// (`docs/assembly-scope.md` §3's Phase 3b - closes the gap Phase 3 left
/// open: Assembly lens was read/view-only, with no in-UI way to add a first
/// component). [insertExistingComponent] is real end to end (see
/// `PartScreen._onInsertComponentPressed`/`add_component.dart`'s
/// `mergeComponentIntoDocument`), as are [addMate] (Phase 6) and
/// [patternComponent] (Phase 7, `docs/assembly-scope.md` §2j) now too;
/// [createNewComponent] alone still has no backing implementation and
/// renders disabled (see [showAssemblyAddMenu]) rather than being omitted,
/// so this menu's shape stays stable once it finally lands.
enum AssemblyAddMenuAction {
  insertExistingComponent,
  createNewComponent,
  addMate,
  patternComponent,
  appearance,
  scenes,
}

/// Shows the Assembly-lens "Add" FAB's flyout - the direct analog of
/// [showAddButtonMenu] for [AssemblyLens.assembly]. Shares
/// [showActionSheet]'s shell with `component_context_menu.dart`'s
/// [showComponentContextMenu] rather than each building its own bottom
/// sheet, since both are flat lists of the same kind of row and several
/// actions (Mate/Pattern) appear in both places.
Future<AssemblyAddMenuAction?> showAssemblyAddMenu(BuildContext context, {Offset? at}) {
  return showContextMenu<AssemblyAddMenuAction>(context, at: at, const [
    ActionSheetEntry(
      action: AssemblyAddMenuAction.insertExistingComponent,
      label: 'Add Component',
      icon: Icons.view_in_ar_outlined,
    ),
    ActionSheetEntry(
      action: AssemblyAddMenuAction.createNewComponent,
      label: 'Create Component…',
      icon: Icons.note_add_outlined,
      // Real as of Phase 15 (`docs/assembly-scope.md` §6): a brand-new
      // in-session Part (`PartScreen._onCreateNewComponentPressed`,
      // `DocumentApiClient.createPart`) merged in the same way "Add
      // Component" merges a picked file (`mergeComponentIntoDocument`),
      // now that Save All/Open Project… give it somewhere real to be saved.
    ),
    ActionSheetEntry(
      action: AssemblyAddMenuAction.addMate,
      label: 'Add Mate',
      icon: Icons.link,
    ),
    ActionSheetEntry(
      action: AssemblyAddMenuAction.patternComponent,
      label: 'Pattern Component',
      icon: Icons.grid_view_outlined,
    ),
    // The Appearance tool (`docs/appearance-tool-scope.md` V3) and scenes (`docs/scenes-scope.md` S3): not additions to
    // the assembly, but the assembly lens's other two whole-assembly tools live in the same flyout.
    ActionSheetEntry(
      action: AssemblyAddMenuAction.appearance,
      label: 'Appearance…',
      icon: Icons.palette_outlined,
    ),
    ActionSheetEntry(
      action: AssemblyAddMenuAction.scenes,
      label: 'Scenes…',
      icon: Icons.photo_camera_back_outlined,
    ),
  ]);
}
