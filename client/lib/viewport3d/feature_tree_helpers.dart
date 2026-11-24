import 'package:material_ui/material_ui.dart';

import '../api/document_api_client.dart';

// What the build tree's rows share with the rest of the client: feature names, the feature icons, which features offer "pin to coarse" and an
// edit panel, and what the sketcher's Convert Entities hands its tree. Moved here from the old build tree panel when it was retired (P3 of
// `docs/assembly-tree-overhaul-scope.md`).

/// The display name for the Feature at [index] in [features] - shared
/// between the tree's own rows and anything else (e.g. the cascade-delete
/// confirmation dialog) that needs to name a Feature the same way the tree
/// does, so the two never drift out of sync. Named per Feature type (e.g.
/// "Sketch 2", "Extrude 1", "Plane 1") rather than by overall position,
/// counting only same-type Features up to and including [index].
String featureDisplayName(List<FeatureDto> features, int index) {
  final feature = features[index];
  final label = switch (feature.type) {
    'extrude' => 'Extrude',
    'surface' => 'Surface',
    'create_plane' => 'Plane',
    'fillet' => 'Fillet',
    'chamfer' => 'Chamfer',
    'revolve' => 'Revolve',
    'sweep' => 'Sweep',
    'loft' => 'Loft',
    // Phase 1 surfacing package: five new surface-producing tools.
    'planar_surface' => 'Planar Surface',
    'revolve_surface' => 'Revolve Surface',
    'swept_surface' => 'Swept Surface',
    'loft_surface' => 'Loft Surface',
    'ruled_surface' => 'Ruled Surface',
    // Phase 2 surfacing package: four new surface-consuming tools.
    'thicken' => 'Thicken',
    'knit_surface' => 'Knit Surface',
    'solid_from_surfaces' => 'Solid from Surfaces',
    'offset_surface' => 'Offset Surface',
    'import' => 'Import',
    'mirror' => 'Mirror',
    'pattern' => 'Pattern',
    // Boolean family, first entry.
    'merge' => 'Merge',
    // Boolean family, Subtract/Common: one shared Feature `type` ("boolean")
    // for both, dispatching on `feature.operation` for the display label -
    // mirrors the gear-family precedent below (6 gear types sharing one
    // glyph with distinct text labels), just for the label instead of the
    // icon.
    'boolean' => feature.operation == 'common' ? 'Common' : 'Subtract',
    // Boolean family, fourth/last entry.
    'split' => 'Split',
    // Direct Editing family, first entry.
    'delete_body' => 'Delete Body',
    // Direct Editing family, second entry.
    'scale_body' => 'Scale',
    // Direct Editing family, third entry ("Move/Copy Body").
    'move_body' => feature.moveBodyCopy == true ? 'Copy Body' : 'Move Body',
    // Direct Editing family, fourth entry.
    'delete_face' => 'Delete Face',
    // Direct Editing family, fifth/last entry.
    'move_face' => 'Move Face',
    'shell' => 'Shell',
    // Gear-tree UX: the gear-family Feature types (built straight from
    // parameters via their own dedicated design screen - GearDesignScreen/
    // BevelDesignScreen/GearChainDesignScreen - never through a Sketch, see
    // `00-conventions.md`'s "gear teeth are not Sketch entities" decision)
    // used to fall into the default arm below and show up mislabelled as a
    // generic "Sketch". Labels match the vocabulary each Feature type's own
    // design screen already uses for it (e.g. GearChainDesignScreen's
    // "Chain"/"Planetary" segmented-button labels), not a bare `feature.type`
    // dump, so a tapped tree row reads the same as the screen it reopens.
    'gear' => 'Gear',
    'rack' => 'Rack',
    'gear_chain' => 'Gear Chain',
    'planetary_gear' => 'Planetary Gear',
    'bevel_gear' => 'Bevel Gear',
    'bevel_pair' => 'Bevel Pair',
    // Curve features: one shared Feature `type` ("curve") for both Helix
    // and Intersection curve, dispatching on `feature.curveType` for the
    // display label - same "shared type, per-value label" convention
    // `'boolean'` above already uses for Subtract/Common.
    'curve' => feature.curveType == 'intersection' ? 'Intersection Curve' : 'Helix',
    'spring' => 'Spring',
    'fill_surface' => 'Fill Surface',
    _ => 'Sketch',
  };
  final ordinal = features.take(index + 1).where((f) => f.type == feature.type).length;
  return '$label $ordinal';
}

/// Maps a Feature's `type` string to its tree-row glyph. `'sketch'` and `'create_plane'` reuse the same asset their own dedicated section already
/// shows (Sketches don't get their own section, but Planes do - both still
/// appear here too since Features lists every Feature unfiltered).
String assemblyTreeFeatureAsset(String type, {String? curveType}) => switch (type) {
      'sketch' => 'assets/icons/feature/feature_new_sketch.svg',
      'extrude' => 'assets/icons/feature/feature_extrude.svg',
      'surface' => 'assets/icons/feature/feature_surface.svg',
      'create_plane' => 'assets/icons/feature/feature_plane.svg',
      'fillet' => 'assets/icons/feature/feature_fillet.svg',
      'chamfer' => 'assets/icons/feature/feature_chamfer.svg',
      'revolve' => 'assets/icons/feature/feature_revolve.svg',
      'sweep' => 'assets/icons/feature/feature_sweep.svg',
      'loft' => 'assets/icons/feature/feature_loft.svg',
      // Phase 1 surfacing package: Revolve/Swept/Loft Surface reuse their
      // solid-tool sibling's own icon (same underlying construction
      // technique, just wire-vs-face - see each backend Feature's own
      // docstring); Planar Surface and Ruled Surface get their own new
      // glyphs (no solid-tool analog to borrow from).
      'planar_surface' => 'assets/icons/feature/feature_planar_surface.svg',
      'revolve_surface' => 'assets/icons/feature/feature_revolve.svg',
      'swept_surface' => 'assets/icons/feature/feature_sweep.svg',
      'loft_surface' => 'assets/icons/feature/feature_loft.svg',
      'ruled_surface' => 'assets/icons/feature/feature_ruled_surface.svg',
      // Phase 2 surfacing package: four new surface-consuming tools, each
      // its own distinct glyph (no solid-tool analog to borrow - see this
      // package's own plan for each icon's concept).
      'thicken' => 'assets/icons/feature/feature_thicken.svg',
      'knit_surface' => 'assets/icons/feature/feature_knit.svg',
      'solid_from_surfaces' => 'assets/icons/feature/feature_solid_from_surfaces.svg',
      'offset_surface' => 'assets/icons/feature/feature_offset_surface.svg',
      'import' => 'assets/icons/feature/parttoolbar_import.svg',
      'mirror' => 'assets/icons/feature/feature_mirror.svg',
      'pattern' => 'assets/icons/feature/feature_pattern.svg',
      // Boolean family, first entry - shared with Subtract/Common's own
      // entries below (see the asset's own file).
      'merge' => 'assets/icons/feature/feature_merge.svg',
      // Boolean family, Subtract/Common: reuses the same Boolean-family
      // glyph Merge does - gear-family precedent just below already
      // establishes "one shared category icon, distinct text labels" for a
      // family of related Feature types.
      'boolean' => 'assets/icons/feature/feature_merge.svg',
      // Boolean family, fourth/last entry: its own distinct glyph, not the
      // shared Merge/Subtract/Common one above - a Split produces 2 Bodies
      // from 1, not 1 from 2+, a visually distinct enough silhouette to be
      // worth its own icon (see `assets/icons/feature/feature_split.svg`).
      'split' => 'assets/icons/feature/feature_split.svg',
      // Direct Editing family, first entry: its own distinct glyph - a
      // DeleteBodyFeature removes geometry entirely rather than combining
      // or splitting it, a different-enough operation to be worth its own
      // icon rather than reusing Merge/Boolean's or Split's.
      'delete_body' => 'assets/icons/feature/feature_delete_body.svg',
      // Direct Editing family, second entry: its own distinct glyph.
      'scale_body' => 'assets/icons/feature/feature_scale.svg',
      // Direct Editing family, third entry ("Move/Copy Body"): its own
      // distinct glyph - Move and Copy share one icon (the tree row's own
      // text label, see `featureDisplayName` above, already distinguishes
      // them), the same "one glyph, distinct labels" convention the
      // Boolean family/gear family already establish.
      'move_body' => 'assets/icons/feature/feature_move_body.svg',
      // Direct Editing family, fourth entry: its own distinct glyph.
      'delete_face' => 'assets/icons/feature/feature_delete_face.svg',
      // Direct Editing family, fifth/last entry: its own distinct glyph.
      'move_face' => 'assets/icons/feature/feature_move_face.svg',
      // Shell: its own distinct glyph (a hollowed, open-topped section).
      'shell' => 'assets/icons/feature/feature_shell.svg',
      // Gear-tree UX: one shared "gear" category glyph for every gear-family
      // Feature type (spur/internal gear, rack, bevel gear, bevel pair, gear
      // chain, planetary set) - they're all built by the same family of
      // dedicated design screens and read as one recognizable category in the
      // tree, the same way `featureDisplayName` above still gives each its
      // own distinct text label.
      'gear' ||
      'rack' ||
      'gear_chain' ||
      'planetary_gear' ||
      'bevel_gear' ||
      'bevel_pair' =>
        'assets/icons/feature/feature_gear.svg',
      // Curve features: a Helix and an Intersection curve each have their own glyph (they used to share Sweep's).
      'curve' => curveType == 'intersection'
          ? 'assets/icons/feature/feature_intersection_curve.svg'
          : 'assets/icons/feature/feature_helix.svg',
      'spring' => 'assets/icons/feature/feature_spring.svg',
      // Fill Surface: reuses the generic Surface glyph (`'surface'`'s own
      // asset) - a filling surface has no more specific existing silhouette
      // to borrow, and it genuinely is a Surface-producing tool.
      'fill_surface' => 'assets/icons/feature/feature_surface.svg',
      _ => 'assets/icons/feature/feature_new_sketch.svg',
    };

/// `docs/lod-strategy/01-design.md` SS3: the feature types the backend can build a coarse stand-in for, so the only ones that offer "pin to
/// coarse".
const Set<String> kCoarseEligibleFeatureTypes = {
  'gear',
  'bevel_gear',
  'bevel_pair',
  'gear_chain',
  'planetary_gear',
  'pattern',
  'loft',
};

/// Whether a feature of [type] has an edit panel to open: an import and a Fill Surface have none.
bool featureTypeHasEditPanel(String type) => switch (type) {
      'import' || 'fill_surface' => false,
      _ => true,
    };

/// What a lost reference says on a feature's row (its tooltip and the bar), from the old panel's subtitle: a sketch's points are re-attached, any
/// other feature's references re-selected.
String lostReferenceReason(FeatureDto f) {
  if (f.type == 'sketch') {
    final n = f.lostReferencePointIds.length;
    return n > 1 ? '$n lost - open to re-attach' : 'open to re-attach';
  }
  final n = f.lostReferences.length;
  return n > 1 ? '$n lost - open to re-select' : 'open to re-select';
}

/// Bug report 2026-11-18 part C3: what the sketcher's locked tree is told while the sketcher is in Convert Entities. Handed down with
/// [TreeConvertPickScope] by the sketcher so the tree builder the Part screen supplies needs no new parameters.
class TreeConvertPick {
  /// The sketch Features that may be picked (the ones earlier in the tree than the sketch being edited): their rows act on a tap.
  final Set<String> pickable;

  /// The pickable sketches already staged (shown ticked).
  final Set<String> picked;

  /// The sketch Features that come LATER: they stay locked, and say why with [laterReason].
  final Set<String> later;
  final String laterReason;

  /// A pickable row was tapped: the id of its sketch Feature.
  final void Function(String featureId) onPick;

  const TreeConvertPick({
    required this.pickable,
    required this.picked,
    required this.later,
    required this.laterReason,
    required this.onPick,
  });
}

/// Carries a [TreeConvertPick] (null: not in Convert Entities) down to the tree built inside it.
class TreeConvertPickScope extends InheritedWidget {
  final TreeConvertPick? pick;

  const TreeConvertPickScope({super.key, required this.pick, required super.child});

  static TreeConvertPick? maybeOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TreeConvertPickScope>()?.pick;

  @override
  bool updateShouldNotify(TreeConvertPickScope oldWidget) => true;
}
