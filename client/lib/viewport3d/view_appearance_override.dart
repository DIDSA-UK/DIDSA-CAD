import 'dart:math' as math;

import 'mesh_geometry.dart' show kSelectOtherDimOpacity;

/// The View menu's Body Colour + Body Transparency as one display override (`docs/view-override-edit-alone-sketch-origin-plan.md`
/// Item 1). While it is set, [PartViewport.appearanceOverride] beats every other appearance (Appearance-tool looks, an
/// Occurrence's colour disc, a shown scene's overrides) on the primary bodies and on every placed instance. Display only:
/// it is never written to the model, a scene, a saved file or an export.
class ViewAppearanceOverride {
  final String colourHex;
  final double opacity;

  const ViewAppearanceOverride({required this.colourHex, required this.opacity});

  @override
  bool operator ==(Object other) =>
      other is ViewAppearanceOverride && other.colourHex == colourHex && other.opacity == opacity;

  @override
  int get hashCode => Object.hash(colourHex, opacity);

  @override
  String toString() => 'ViewAppearanceOverride($colourHex, $opacity)';
}

/// What one body or placed instance should wear. [colourHex] null means the builder's own default colour.
class ResolvedLook {
  final String? colourHex;
  final double opacity;

  /// True when the Appearance tool's look should be applied on top (never while an override is set).
  final bool useLook;

  const ResolvedLook({required this.colourHex, required this.opacity, required this.useLook});

  @override
  bool operator ==(Object other) =>
      other is ResolvedLook && other.colourHex == colourHex && other.opacity == opacity && other.useLook == useLook;

  @override
  int get hashCode => Object.hash(colourHex, opacity, useLook);

  @override
  String toString() => 'ResolvedLook($colourHex, $opacity, useLook: $useLook)';
}

/// A placed (sub-part or sub-assembly) instance. [fade] is `assemblyInstanceOpacity` (1.0 focused / 0.25 context),
/// [dim] is the Select Other dim. With an override the colour is the override's and the opacity is its opacity times the
/// focus fade (context still reads as context), then the Select Other dim as a `min`, as today.
ResolvedLook resolveInstanceLook({
  required ViewAppearanceOverride? override,
  required bool hasLook,
  required String? tintHex,
  required double fade,
  required bool dim,
}) {
  final base = override == null ? fade : override.opacity * fade;
  return ResolvedLook(
    colourHex: override?.colourHex ?? tintHex,
    opacity: dim ? math.min(base, kSelectOtherDimOpacity) : base,
    useLook: override == null && hasLook,
  );
}

/// The primary bodies (the root Part's own, or the focused Part's). [baseColourHex] / [baseOpacity] are the non-override
/// colour and opacity (the default grey / the sketch screen's session values).
ResolvedLook resolvePrimaryLook({
  required ViewAppearanceOverride? override,
  required bool hasLook,
  required String? focusColourHex,
  required String baseColourHex,
  required double baseOpacity,
  required bool dim,
}) {
  final base = override?.opacity ?? baseOpacity;
  return ResolvedLook(
    colourHex: override?.colourHex ?? focusColourHex ?? baseColourHex,
    opacity: dim ? math.min(base, kSelectOtherDimOpacity) : base,
    useLook: override == null && hasLook,
  );
}
