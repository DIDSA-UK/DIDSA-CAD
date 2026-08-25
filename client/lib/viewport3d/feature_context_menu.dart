import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Actions available from a Feature's long-press context menu. Stage 8 adds
/// [toggleVisibility] above the existing [delete]; Stage 9 adds [extrude]
/// above both; Prompt F adds [revolve] alongside [extrude]; Sweep adds
/// [sweep] alongside both; the sketcher-roadmap feedback round adds
/// [redefineOrientation]; Pattern/Mirror scoping's Phase 6 adds [pattern]
/// (on-device feedback: "user should now be able to start pattern from
/// long press a feature in the tree") - later stages can add further
/// entries here without changing how the menu itself is shown or wired up.
///
/// Pattern/Mirror scoping's Phase 9 (`docs/pattern-mirror-scope.md`
/// §2.12/§4) adds [mirror] (the entry-point asymmetry this phase fixes:
/// [pattern] already had this "seed from this Feature via
/// `source_feature_ids`" entry, Mirror never did) and folds Phase 8's
/// separate [patternIntoTarget]/[mirrorIntoTarget] entries back into
/// [pattern]/[mirror] themselves - a Feature eligible for the
/// `tool_feature_id` seed mode (see `PartScreen._isEligibleToolFeature`)
/// now shows the same single "Pattern"/"Mirror" entry as any other
/// body-producing Feature, with the choice of which of the two mutually-
/// exclusive seed fields to use surfaced as a toggle *inside* the opened
/// panel instead (`PatternPanel.seedKind`/`MirrorPanel.seedKind`) - see
/// [showPattern]'s own doc comment for the widened gate this implies.
/// Boolean family, first entry (Merge): [merge] mirrors [pattern]/[mirror]'s
/// own "seed from this Feature" entry exactly - shown for any Feature that
/// mints a Body of its own (see [showMerge]'s own doc comment).
///
/// Bug fix: [surface] gives Extrude Surface the same long-press-on-Sketch
/// route Extrude/Revolve/Sweep already have - previously the only way to
/// create one was Add > Feature > Surfacing, with no shortcut from the tree
/// itself (see [showSurface]'s own doc comment).
enum FeatureContextMenuAction {
  extrude,
  revolve,
  sweep,
  surface,
  redefineOrientation,
  pattern,
  mirror,
  merge,
  toggleVisibility,
  delete,
}

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
///
/// Bug fix: [showSurface] gates the "Extrude Surface" entry - only a
/// SketchFeature offers it (same "only a SketchFeature" gate as Extrude/
/// Revolve/Sweep), but unlike those three it's always enabled when shown -
/// a Surface has no closed-profile eligibility restriction at all (it
/// accepts even a single open wire, see the backend `SurfaceFeature`'s own
/// docstring), so this mirrors [showPattern]/[showMirror]'s simpler
/// always-enabled shape, not [showExtrude]'s canX/disabledReason one.
///
/// Pattern/Mirror scoping's Phase 6: [showPattern] gates the "Pattern"
/// entry - shown for any Feature that mints a Body of its own (Extrude/
/// Revolve/Sweep/Import/Mirror/Pattern, mirrors `PartScreen`'s own
/// `_bodyProducingFeatureTypes`), always enabled when shown (no
/// eligibility check needed - `source_feature_ids` resolves against
/// whatever the Feature currently produces, at solve time, same as every
/// other Feature-tree-as-selection-source use).
///
/// Pattern/Mirror scoping's Phase 9 (`docs/pattern-mirror-scope.md`
/// §2.12/§4): [showPattern]'s own gate widened to the *union* of
/// `_bodyProducingFeatureTypes` and the backend's own
/// `invalid_tool_feature_ref` eligibility check (`PartScreen.
/// _isEligibleToolFeature` - an Extrude/Revolve/Sweep in Cut mode, or Boss
/// mode with a non-empty `target_body_ids`) - folding Phase 8's separate
/// "Pattern into Target"/"Mirror into Target" entries back into this one
/// (see [FeatureContextMenuAction]'s own doc comment). [showMirror] mirrors
/// [showPattern] exactly - the entry-point asymmetry this phase fixes (see
/// [FeatureContextMenuAction.mirror]'s own doc comment). Both stay always-
/// enabled-when-shown, same reasoning as before.
/// Boolean family, first entry: [showMerge] gates the "Merge" entry -
/// mirrors [showPattern]/[showMirror]'s own gate exactly (any Feature that
/// mints a Body of its own - `PartScreen._bodyProducingFeatureTypes`), no
/// `tool_feature_id`-style widening (Merge has no such mode). Always
/// enabled when shown, same reasoning as [showPattern]/[showMirror].
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
  bool showSurface = false,
  bool showPattern = false,
  bool showMirror = false,
  bool showMerge = false,
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
            if (showSurface)
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_surface.svg'),
                title: const Text('Extrude Surface'),
                onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.surface),
              ),
            if (showPattern)
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_pattern.svg'),
                title: const Text('Pattern'),
                onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.pattern),
              ),
            if (showMirror)
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_mirror.svg'),
                title: const Text('Mirror'),
                onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.mirror),
              ),
            if (showMerge)
              ListTile(
                leading: const SvgIcon('assets/icons/feature/feature_merge.svg'),
                title: const Text('Merge'),
                onTap: () => Navigator.of(context).pop(FeatureContextMenuAction.merge),
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
