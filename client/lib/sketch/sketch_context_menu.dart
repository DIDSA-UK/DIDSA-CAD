import 'dart:async';

import 'package:flutter/material.dart';

import '../viewport3d/action_sheet.dart';
import '../viewport3d/keyboard_shortcuts.dart';
import '../viewport3d/svg_icon.dart';
import 'sketch_controller.dart';
import 'sketch_ribbon.dart';

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): the sketch's
/// right-click menus. Each entry carries the callback it runs, so the menu
/// resolves to a [VoidCallback] that is simply called - the same controller
/// calls the ribbon's chips and the sketch shortcuts already make.

/// Right click on a selected sketch entity (or several): the ribbon's main
/// actions - Delete, Construction on / off, Fix / Unfix, and the constraints
/// it offers for this selection.
Future<void> showSketchEntityContextMenu(BuildContext context, SketchController controller, {required Offset at}) async {
  final selectionSet = controller.selectionSet;
  if (selectionSet.isEmpty) return;
  final busy = controller.busy;
  final single = selectionSet.length == 1 ? selectionSet.first : null;
  final isPatternOrMirror = single?.kind == SelectionKind.patternInstance || single?.kind == SelectionKind.mirrorInstance;
  final construction = controller.availableConstructionToggles;
  final fix = controller.availableFixToggles;
  final deleteAction = sketchDeleteAction(context, controller);
  final deleteReason = single?.kind == SelectionKind.point ? controller.selectedPointDeleteBlockedReason : null;
  final theme = Theme.of(context);

  final action = await showContextMenu<VoidCallback>(context, at: at, [
    if (isPatternOrMirror)
      ActionSheetEntry(
        action: () => single.kind == SelectionKind.mirrorInstance
            ? controller.startEditingMirrorInstance(single.id)
            : controller.startEditingPatternInstance(single.id),
        label: single!.kind == SelectionKind.mirrorInstance ? 'Edit Mirror' : 'Edit Pattern',
        leading: const SvgIcon('assets/icons/feature/feature_pattern.svg'),
        enabled: !busy,
      ),
    if (construction.showMakeConstruction)
      ActionSheetEntry(
        action: () => unawaited(controller.setSelectedConstruction(true)),
        label: 'Make Construction',
        leading: const SvgIcon('assets/icons/ribbon/ribbon_make_construction.svg'),
        shortcut: kCadShortcuts[CadShortcut.sketchConstruction]!.keys,
        enabled: !busy,
      ),
    if (construction.showMakeSolid)
      ActionSheetEntry(
        action: () => unawaited(controller.setSelectedConstruction(false)),
        label: 'Make Solid',
        leading: const SvgIcon('assets/icons/ribbon/ribbon_make_construction.svg'),
        shortcut: kCadShortcuts[CadShortcut.sketchConstruction]!.keys,
        enabled: !busy,
      ),
    if (fix.showFix)
      ActionSheetEntry(
        action: () => unawaited(controller.fixSelected()),
        label: 'Fix',
        leading: SvgIcon(sketchConstraintSvgAsset(ConstraintOptionType.fix)),
        enabled: !busy,
      ),
    if (fix.showUnfix)
      ActionSheetEntry(
        action: () => unawaited(controller.unfixSelected()),
        label: 'Unfix',
        leading: SvgIcon(sketchConstraintSvgAsset(ConstraintOptionType.unfix)),
        enabled: !busy,
      ),
    for (final option in controller.availableConstraintOptions)
      ActionSheetEntry(
        action: () => unawaited(controller.applyConstraintOption(option.type)),
        label: option.label,
        leading: SvgIcon(sketchConstraintSvgAsset(option.type)),
        enabled: option.wired && !busy,
        disabledReason: option.wired ? null : 'Not available yet',
      ),
    ActionSheetEntry(
      action: deleteAction ?? () {},
      label: isPatternOrMirror ? (single!.kind == SelectionKind.mirrorInstance ? 'Delete Mirror' : 'Delete Pattern') : 'Delete',
      icon: Icons.delete_outline,
      iconColor: theme.colorScheme.error,
      shortcut: kCadShortcuts[CadShortcut.delete]!.keys,
      enabled: deleteAction != null,
      disabledReason: deleteReason,
      dividerBefore: true,
    ),
  ]);
  action?.call();
}

/// Right click on empty canvas: the draw tools (with their keys), Select
/// all and Zoom to fit. [onZoomToFit] is the screen's own fit (the 2D
/// canvas, or Orbit View's 3D view).
Future<void> showSketchBackgroundContextMenu(
  BuildContext context,
  SketchController controller, {
  required Offset at,
  VoidCallback? onZoomToFit,
}) async {
  final idle = !controller.busy;
  String keys(CadShortcut shortcut) => kCadShortcuts[shortcut]!.keys;
  ActionSheetEntry<VoidCallback> tool(String label, String asset, SketchTool sketchTool, CadShortcut shortcut) => ActionSheetEntry(
        action: () => controller.selectDrawTool(sketchTool),
        label: label,
        leading: SvgIcon(asset),
        shortcut: keys(shortcut),
        enabled: idle,
      );
  final action = await showContextMenu<VoidCallback>(context, at: at, [
    tool('Line', 'assets/icons/sketch_tools/sketch_tool_line.svg', SketchTool.line, CadShortcut.sketchLine),
    tool('Circle', 'assets/icons/sketch_tools/sketch_tool_circle.svg', SketchTool.circle, CadShortcut.sketchCircle),
    tool('Arc', 'assets/icons/sketch_tools/sketch_tool_arc.svg', SketchTool.arc, CadShortcut.sketchArc),
    tool('Rectangle', 'assets/icons/sketch_tools/sketch_tool_rectangle.svg', SketchTool.rectangle, CadShortcut.sketchRectangle),
    ActionSheetEntry(
      action: controller.enterDimensionMode,
      label: 'Dimension',
      leading: const SvgIcon('assets/icons/actions/action_dimensions.svg'),
      shortcut: keys(CadShortcut.sketchDimension),
      enabled: idle,
    ),
    ActionSheetEntry(
      action: controller.enterTrimMode,
      label: 'Trim',
      leading: const SvgIcon('assets/icons/actions/action_trim.svg'),
      shortcut: keys(CadShortcut.sketchTrim),
      enabled: idle,
    ),
    ActionSheetEntry(
      action: controller.selectAll,
      label: 'Select All',
      leading: const SvgIcon('assets/icons/sketchbar/sketchbar_select_all.svg'),
      shortcut: keys(CadShortcut.selectAll),
      enabled: idle && controller.mode == SketchMode.select,
      dividerBefore: true,
    ),
    if (onZoomToFit != null)
      ActionSheetEntry(
        action: onZoomToFit,
        label: 'Zoom to Fit',
        icon: Icons.zoom_out_map,
        shortcut: keys(CadShortcut.zoomToFit),
      ),
  ]);
  action?.call();
}
