import 'package:flutter/material.dart';

import 'action_sheet.dart';
import 'keyboard_shortcuts.dart';
import 'part_viewport.dart' show StandardView;

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): what a mouse
/// right click on part geometry offers - SOLIDWORKS' face/edge/vertex menu.
/// The owning body's own items (Hide / Show, Assign Material) follow the
/// geometry ones, after a divider.
enum GeometryMenuAction { selectOther, zoomToSelection, normalTo, measure, appearance, toggleBodyVisibility, assignMaterial }

/// [at] is the click's global position. A null [bodyHidden] means the
/// click was not on a body of this part (a placed component's face, say),
/// so the body items are left out.
Future<GeometryMenuAction?> showGeometryContextMenu(
  BuildContext context, {
  required Offset at,
  required bool canSelectOther,
  required bool canNormalTo,
  required bool canMeasure,
  required bool canAppearance,
  String? measureDisabledReason,
  bool? bodyHidden,
}) {
  return showContextMenu<GeometryMenuAction>(context, at: at, [
    ActionSheetEntry(
      action: GeometryMenuAction.selectOther,
      label: 'Select Other',
      icon: Icons.layers_outlined,
      enabled: canSelectOther,
      disabledReason: 'Nothing else under the cursor',
    ),
    const ActionSheetEntry(
      action: GeometryMenuAction.zoomToSelection,
      label: 'Zoom to Selection',
      icon: Icons.zoom_in_map,
    ),
    ActionSheetEntry(
      action: GeometryMenuAction.normalTo,
      label: 'Normal To',
      icon: Icons.crop_free,
      enabled: canNormalTo,
      disabledReason: 'Only a flat face has a normal',
    ),
    ActionSheetEntry(
      action: GeometryMenuAction.measure,
      label: 'Measure',
      icon: Icons.straighten,
      enabled: canMeasure,
      disabledReason: measureDisabledReason ?? 'Pick a face, edge or vertex',
    ),
    ActionSheetEntry(
      action: GeometryMenuAction.appearance,
      label: 'Appearance...',
      icon: Icons.palette_outlined,
      enabled: canAppearance,
      disabledReason: 'Pick a face or a body',
    ),
    if (bodyHidden != null) ...[
      ActionSheetEntry(
        action: GeometryMenuAction.toggleBodyVisibility,
        label: bodyHidden ? 'Show Body' : 'Hide Body',
        icon: bodyHidden ? Icons.visibility : Icons.visibility_off,
        dividerBefore: true,
      ),
      const ActionSheetEntry(
        action: GeometryMenuAction.assignMaterial,
        label: 'Assign Material',
        icon: Icons.science_outlined,
      ),
    ],
  ]);
}

/// What a right click on empty 3D space offers.
enum ViewMenuAction { zoomToFit, standardViews, togglePerspective, toggleReferencePlanes, resetView }

Future<ViewMenuAction?> showViewContextMenu(
  BuildContext context, {
  required Offset at,
  required bool isPerspective,
  required bool referencePlanesHidden,
}) {
  return showContextMenu<ViewMenuAction>(context, at: at, [
    ActionSheetEntry(
      action: ViewMenuAction.zoomToFit,
      label: 'Zoom to Fit',
      icon: Icons.zoom_out_map,
      shortcut: kCadShortcuts[CadShortcut.zoomToFit]!.keys,
    ),
    const ActionSheetEntry(
      action: ViewMenuAction.standardViews,
      label: 'Standard Views',
      icon: Icons.view_in_ar_outlined,
      shortcut: '>',
    ),
    ActionSheetEntry(
      action: ViewMenuAction.togglePerspective,
      label: isPerspective ? 'Orthographic' : 'Perspective',
      icon: isPerspective ? Icons.crop_square : Icons.panorama_horizontal_outlined,
      shortcut: kCadShortcuts[CadShortcut.togglePerspective]!.keys,
    ),
    ActionSheetEntry(
      action: ViewMenuAction.toggleReferencePlanes,
      label: referencePlanesHidden ? 'Show Reference Planes' : 'Hide Reference Planes',
      icon: referencePlanesHidden ? Icons.visibility : Icons.visibility_off,
    ),
    const ActionSheetEntry(
      action: ViewMenuAction.resetView,
      label: 'Reset View',
      icon: Icons.restart_alt,
      dividerBefore: true,
    ),
  ]);
}

/// The "Standard Views" submenu, shown at the same place once chosen from
/// [showViewContextMenu] (a popup menu has no flyouts, so it is a second
/// popup rather than a side panel).
Future<StandardView?> showStandardViewsMenu(BuildContext context, {required Offset at}) {
  String keys(CadShortcut shortcut) => kCadShortcuts[shortcut]!.keys;
  return showContextMenu<StandardView>(context, at: at, [
    ActionSheetEntry(action: StandardView.front, label: 'Front', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewFront)),
    ActionSheetEntry(action: StandardView.back, label: 'Back', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewBack)),
    ActionSheetEntry(action: StandardView.left, label: 'Left', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewLeft)),
    ActionSheetEntry(action: StandardView.right, label: 'Right', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewRight)),
    ActionSheetEntry(action: StandardView.top, label: 'Top', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewTop)),
    ActionSheetEntry(action: StandardView.bottom, label: 'Bottom', icon: Icons.view_in_ar_outlined, shortcut: keys(CadShortcut.viewBottom)),
    ActionSheetEntry(
      action: StandardView.isometric,
      label: 'Isometric',
      icon: Icons.view_in_ar_outlined,
      shortcut: keys(CadShortcut.viewIsometric),
    ),
  ]);
}
