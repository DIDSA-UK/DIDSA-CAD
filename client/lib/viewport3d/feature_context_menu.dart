import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Actions available from a Feature's long-press context menu. Stage 8 adds
/// [toggleVisibility] above the existing [delete]; Stage 9 adds [extrude]
/// above both; Prompt F adds [revolve] alongside [extrude]; Sweep adds
/// [sweep] alongside both; the sketcher-roadmap feedback round adds
/// [redefineOrientation] - later stages can add further entries here
/// without changing how the menu itself is shown or wired up.
enum FeatureContextMenuAction { extrude, revolve, sweep, redefineOrientation, toggleVisibility, delete }

/// Shows a bottom sheet of actions for a single Feature, opened by a
/// long-press on its row in the tree. A bottom sheet - rather than wiring
/// long-press directly to a single action - is what lets later stages add
/// more entries alongside Delete without restructuring this call site or
/// [FeatureTreePanel].
///
/// [isHidden] selects the Hide/Show label and icon for the toggle-visibility
/// entry, reflecting that Feature's current state in [PartScreen].
///
/// [showExtrude] gates the Extrude entry's presence entirely - only a
/// SketchFeature can be extruded, so an ExtrudeFeature row passes `false`
/// and gets no entry at all. When shown, [canExtrude] (the closed-profile
/// check the caller already ran when the menu was opened, not on every
/// render) determines whether it's enabled; when disabled,
/// [extrudeDisabledReason] is shown as its subtitle.
///
/// Prompt F: [showRevolve]/[canRevolve]/[revolveDisabledReason] mirror
/// [showExtrude]/[canExtrude]/[extrudeDisabledReason] exactly - same
/// closed-profile eligibility, same "only a SketchFeature gets this entry"
/// gate. [showSweep]/[canSweep]/[sweepDisabledReason] mirror both the same
/// way.
///
/// [showRedefineOrientation] gates the "Sketch Orientation" entry - only a
/// SketchFeature offers it (same "only a SketchFeature" gate as Extrude/
/// Revolve/Sweep), always enabled when shown (no eligibility check, unlike
/// those three). Sketcher-roadmap feedback round: this is now the sole way
/// to redefine an existing Sketch's orientation - the old 2D-only
/// hamburger-menu sheet gave the user no 3D reference to judge flip/rotate
/// against, so it's gone; this reuses the same 3D-viewport orientation
/// confirm step a brand new Sketch already shows.
Future<FeatureContextMenuAction?> showFeatureContextMenu(
  BuildContext context, {
  required bool isHidden,
  bool showExtrude = false,
  bool canExtrude = false,
  String? extrudeDisabledReason,
  bool showRevolve = false,
  bool canRevolve = false,
  String? revolveDisabledReason,
  bool showSweep = false,
  bool canSweep = false,
  String? sweepDisabledReason,
  bool showRedefineOrientation = false,
}) {
  return showModalBottomSheet<FeatureContextMenuAction>(
    context: context,
    // Revolve/Sweep joining Extrude means up to 5 entries (3 of them with a
    // wrapping subtitle) can appear at once - a plain Column overflows a
    // short screen/test surface, so this needs to scroll rather than clip.
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (showExtrude)
              ListTile(
                enabled: canExtrude,
                leading: const SvgIcon('assets/icons/feature/feature_extrude.svg'),
                title: const Text('Extrude'),
                subtitle: canExtrude ? null : Text(extrudeDisabledReason ?? 'Not available'),
                onTap: canExtrude
                    ? () => Navigator.of(context).pop(FeatureContextMenuAction.extrude)
                    : null,
              ),
            if (showRevolve)
              ListTile(
                enabled: canRevolve,
                leading: const SvgIcon('assets/icons/feature/feature_revolve.svg'),
                title: const Text('Revolve'),
                subtitle: canRevolve ? null : Text(revolveDisabledReason ?? 'Not available'),
                onTap: canRevolve
                    ? () => Navigator.of(context).pop(FeatureContextMenuAction.revolve)
                    : null,
              ),
            if (showSweep)
              ListTile(
                enabled: canSweep,
                leading: const SvgIcon('assets/icons/feature/feature_sweep.svg'),
                title: const Text('Sweep'),
                subtitle: canSweep ? null : Text(sweepDisabledReason ?? 'Not available'),
                onTap: canSweep
                    ? () => Navigator.of(context).pop(FeatureContextMenuAction.sweep)
                    : null,
              ),
            if (showRedefineOrientation)
              ListTile(
                leading: const Icon(Icons.rotate_90_degrees_ccw),
                title: const Text('Sketch Orientation'),
                onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.redefineOrientation),
              ),
            ListTile(
              leading: Icon(isHidden ? Icons.visibility : Icons.visibility_off),
              title: Text(isHidden ? 'Show' : 'Hide'),
              onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.toggleVisibility),
            ),
            ListTile(
              leading: const Icon(Icons.delete, color: Colors.red),
              title: const Text('Delete'),
              onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.delete),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Actions available from a Body row's long-press context menu. Only
/// [toggleVisibility] exists today - a Body can't be renamed or deleted
/// directly (that's done via the Feature that produced it) - but this stays
/// an enum + bottom sheet, matching [FeatureContextMenuAction]/
/// [showFeatureContextMenu]'s own shape, so a later stage can add more
/// entries here without restructuring this call site or [FeatureTreePanel].
enum BodyContextMenuAction { toggleVisibility }

/// On-device feedback: a Body row's long-press used to toggle Hide/Show
/// directly; this instead shows a bottom sheet in the same style as
/// [showFeatureContextMenu], with Hide/Show as its one entry.
Future<BodyContextMenuAction?> showBodyContextMenu(
  BuildContext context, {
  required bool isHidden,
}) {
  return showModalBottomSheet<BodyContextMenuAction>(
    context: context,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          ListTile(
            leading: Icon(isHidden ? Icons.visibility : Icons.visibility_off),
            title: Text(isHidden ? 'Show' : 'Hide'),
            onTap: () => Navigator.of(context).pop(BodyContextMenuAction.toggleVisibility),
          ),
        ],
      ),
    ),
  );
}
