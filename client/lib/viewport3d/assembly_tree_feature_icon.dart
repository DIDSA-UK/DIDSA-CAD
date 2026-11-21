// The feature type -> icon asset map the tree rows use (the same glyphs as the old build tree panel, which keeps its own private copy until it
// is retired in P3).

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
/// coarse" (the old panel's private `_coarseEligibleFeatureTypes`, which goes with it in P3).
const Set<String> kCoarseEligibleFeatureTypes = {
  'gear',
  'bevel_gear',
  'bevel_pair',
  'gear_chain',
  'planetary_gear',
  'pattern',
  'loft',
};

/// Whether a feature of [type] has an edit panel to open: an import and a Fill Surface have none (the old panel's private `_hasEditPanel`).
bool featureTypeHasEditPanel(String type) => switch (type) {
      'import' || 'fill_surface' => false,
      _ => true,
    };
