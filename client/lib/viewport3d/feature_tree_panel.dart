import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

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
    'create_plane' => 'Plane',
    _ => 'Sketch',
  };
  final ordinal = features.take(index + 1).where((f) => f.type == feature.type).length;
  return '$label $ordinal';
}

/// The "Build Tree": a Part's currently-computed Bodies (top, collapsible)
/// followed by its user-authored Features (Sketch/Extrude/etc, also
/// collapsible), in creation order. B3 revision, off on-device feedback:
/// Bodies are real produced objects (`bodyIds`/`bodyNames`), not Feature
/// rows - a single Feature that splits into multiple Bodies (A1's
/// multi-solid amendment) now genuinely shows as multiple Body entries
/// here, which the original B3 pass deliberately (and, per that feedback,
/// wrongly) avoided doing. Planes/Surfaces sections are meant to sit
/// alongside Bodies once Create Plane/Fillet (C/D/E) actually produce
/// something to list - no such data source exists yet, so there is nothing
/// to render for them today.
///
/// Locked Features (every Feature except the last) are shown greyed out
/// with a lock icon and remain tappable - a tap only selects/highlights
/// them, per the project brief - while the editable (last) Feature is
/// tappable to open it for editing. Selection is purely a display concern
/// here; [onFeatureTap] decides what a tap actually does. A long-press on
/// any row (locked or not) invokes [onFeatureLongPress] - unlike a tap,
/// this is available regardless of lock state, since the cascade-delete
/// action it can lead to also removes everything after a locked Feature
/// that depends on it. Tapping a Body row calls [onBodyTap] instead -
/// Bodies aren't edited directly, only selected/highlighted (the same way
/// tapping one in the 3D viewport already does).
///
/// Hidden by default so the 3D viewport gets full space - slides in from
/// the left (same [AnimatedSlide] pattern as [SketchRibbon]) when
/// [visible], capped to 40% of the available width so the viewport stays
/// visible alongside it rather than being fully covered, with its own
/// close button ([onClose]) rather than relying solely on the toolbar
/// toggle that opened it.
class FeatureTreePanel extends StatelessWidget {
  final bool visible;
  final List<FeatureDto> features;
  final String? selectedFeatureId;
  final void Function(FeatureDto feature) onFeatureTap;
  final void Function(FeatureDto feature) onFeatureLongPress;
  final VoidCallback onClose;

  /// The Part's currently-computed Body ids (from `GET /mesh`, `source:
  /// "computed"` entries only - the dev-time placeholder box is never a
  /// real Body and never appears here) - [PartScreen] already fetches
  /// these for the 3D viewport itself, so no separate network call is
  /// needed just to populate this section.
  final List<String> bodyIds;

  /// Stable "Body 1"/"Body 2"... display names for [bodyIds] - see
  /// `body_naming.dart`'s `bodyDisplayNames`, the same map
  /// [SelectionListDrawer] uses so a Body is called the same thing
  /// everywhere.
  final Map<String, String> bodyNames;

  /// Tapping a row in the Bodies section - selects/highlights that Body,
  /// mirroring what tapping it directly in the 3D viewport already does.
  final void Function(String bodyId) onBodyTap;

  /// Feature ids hidden from the 3D viewport (see [PartScreen]'s Hide/Show
  /// context-menu action) - shown here as a dimmed row with an eye-slash
  /// icon, so hidden state is visible from the tree, not just invisible by
  /// its absence in the 3D view.
  final Set<String> hiddenFeatureIds;

  /// Prompt D: true while the tree is acting as a Sketch picker for a
  /// pending Extrude (entered from the "Add" FAB's Feature > Extrude entry
  /// when no eligible Sketch is already selected) - shows the picker banner
  /// below and switches every row's tap from [onFeatureTap] to
  /// [onSketchPicked].
  final bool isSketchPickerMode;

  /// While [isSketchPickerMode], the ids of Sketch Features with a closed
  /// profile - the rest (including every non-Sketch Feature) render dimmed.
  /// Purely a visual aid: [onSketchPicked] re-validates the tapped Sketch
  /// itself, so a stale/in-flight value here never lets an ineligible
  /// Sketch through.
  final Set<String> pickableSketchIds;

  /// [isSketchPickerMode]'s tap handler - called for a Sketch Feature row
  /// tap instead of [onFeatureTap]. Unused (and may be left null) outside
  /// picker mode.
  final void Function(FeatureDto feature)? onSketchPicked;

  const FeatureTreePanel({
    super.key,
    required this.visible,
    required this.features,
    required this.selectedFeatureId,
    required this.onFeatureTap,
    required this.onFeatureLongPress,
    required this.onClose,
    required this.onBodyTap,
    this.bodyIds = const [],
    this.bodyNames = const {},
    this.hiddenFeatureIds = const {},
    this.isSketchPickerMode = false,
    this.pickableSketchIds = const {},
    this.onSketchPicked,
  });

  @override
  Widget build(BuildContext context) {
    return Align(
      alignment: Alignment.topLeft,
      child: ClipRect(
        child: AnimatedSlide(
          offset: visible ? Offset.zero : const Offset(-1.05, 0),
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          child: SafeArea(
            child: FractionallySizedBox(
              widthFactor: 0.4,
              heightFactor: 1,
              child: Material(
                elevation: 2,
                borderRadius: const BorderRadius.only(
                  topRight: Radius.circular(12),
                  bottomRight: Radius.circular(12),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
                      child: Row(
                        children: [
                          const Expanded(
                            child: Text('Build Tree', style: TextStyle(fontWeight: FontWeight.bold)),
                          ),
                          IconButton(
                            tooltip: 'Close',
                            icon: const Icon(Icons.close, size: 20),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    // Prompt D: an inline banner (not a dialog) naming the
                    // picker mode the user is in - sits below the header so
                    // the close (X) button stays usable to cancel the
                    // pending Extrude.
                    if (isSketchPickerMode)
                      Container(
                        width: double.infinity,
                        color: Theme.of(context).colorScheme.surfaceContainerHighest,
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                        child: Text(
                          'Select a sketch to extrude',
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.onSurfaceVariant,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    Expanded(child: _buildGroupedTree(context)),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// B3 revision: Bodies (real produced objects) at the top, Features
  /// (Sketch/Extrude/etc, the full unfiltered creation-order list) below -
  /// both collapsible, mirroring [PartToolbar]'s File/View/Selection-
  /// Filters [ExpansionTile] convention rather than inventing a new
  /// grouping widget. Neither section reorders anything - Bodies are
  /// ordered by `bodyDisplayNames` (Feature-creation order, then split
  /// index), and Features keep [features]' own creation/graph order
  /// exactly as before this prompt.
  Widget _buildGroupedTree(BuildContext context) {
    return ListView(
      children: [
        if (bodyIds.isNotEmpty) _buildBodiesSection(context),
        if (features.any((f) => f.type == 'create_plane')) _buildPlanesSection(context),
        _buildFeaturesSection(context),
      ],
    );
  }

  /// The Bodies section - omitted entirely when [bodyIds] is empty (e.g. a
  /// Part with no real geometry yet), rather than shown as an empty/error
  /// section. Row order follows [bodyNames]' own iteration order (a
  /// `LinkedHashMap`, so it preserves `bodyDisplayNames`' already-correct
  /// "Body 1", "Body 2", ... insertion order) rather than re-sorting
  /// [bodyIds] here by the display name *string* - "Body 10" would
  /// otherwise sort before "Body 2".
  Widget _buildBodiesSection(BuildContext context) {
    final orderedIds = bodyNames.keys.where(bodyIds.contains).toList();
    return ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(Icons.view_in_ar),
      title: const Text('Bodies'),
      children: [
        for (final bodyId in orderedIds)
          ListTile(
            leading: const Icon(Icons.view_in_ar_outlined),
            title: Text(bodyNames[bodyId] ?? bodyId),
            onTap: () => onBodyTap(bodyId),
          ),
      ],
    );
  }

  /// C2: the Planes section - real produced Plane objects, one row per
  /// CreatePlaneFeature (always 1:1, unlike Bodies' potential Feature-to-
  /// multiple-Bodies split, so this needs no separate id/name map the way
  /// [_buildBodiesSection] does). Omitted entirely when there are none yet
  /// (see [_buildGroupedTree]'s own check), same "no empty section" rule
  /// [_buildBodiesSection] follows. Tapping a row reuses [onFeatureTap] -
  /// same B4 rollback/edit flow a Features-section row already opens for
  /// this same Feature, not a separate select-only action the way tapping a
  /// Body row is.
  Widget _buildPlanesSection(BuildContext context) {
    final planeFeatures = features.where((f) => f.type == 'create_plane').toList();
    return ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(Icons.crop_din),
      title: const Text('Planes'),
      children: [
        for (final feature in planeFeatures)
          ListTile(
            leading: const Icon(Icons.crop_din_outlined),
            title: Text(featureDisplayName(features, features.indexOf(feature))),
            onTap: () => onFeatureTap(feature),
          ),
      ],
    );
  }

  /// The Features section - always shown (even if empty, which can only
  /// happen for a brand-new Part with nothing in it yet - an
  /// [ExpansionTile] with no children is a normal, sane empty state, not an
  /// error one).
  Widget _buildFeaturesSection(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: true,
      leading: const Icon(Icons.list_alt),
      title: const Text('Features'),
      children: [for (final feature in features) _buildFeatureTile(context, feature)],
    );
  }

  /// One Feature's row inside the Features section - unchanged in
  /// behaviour/appearance from before B3's revision.
  Widget _buildFeatureTile(BuildContext context, FeatureDto feature) {
    final index = features.indexWhere((f) => f.id == feature.id);
    final selected = feature.id == selectedFeatureId;
    final hidden = hiddenFeatureIds.contains(feature.id);
    final isSketch = feature.type == 'sketch';
    // Dimmed (but still tappable - an ineligible tap surfaces a SnackBar via
    // onSketchPicked rather than being inert) whenever picking and this row
    // isn't a Sketch with a known-closed profile.
    final pickerDimmed = isSketchPickerMode && (!isSketch || !pickableSketchIds.contains(feature.id));
    return Opacity(
      opacity: hidden || pickerDimmed ? 0.5 : 1.0,
      child: ListTile(
        selected: selected,
        leading: Icon(
          feature.locked
              ? Icons.lock
              : switch (feature.type) {
                  'extrude' => Icons.view_in_ar,
                  'create_plane' => Icons.crop_din,
                  _ => Icons.edit,
                },
          color: feature.locked ? Colors.grey : Theme.of(context).colorScheme.primary,
        ),
        title: Text(featureDisplayName(features, index)),
        subtitle: Text(feature.locked ? 'Locked' : 'Editable'),
        trailing: hidden ? const Icon(Icons.visibility_off, size: 18) : null,
        onTap: () {
          if (isSketchPickerMode) {
            if (isSketch) onSketchPicked?.call(feature);
          } else {
            onFeatureTap(feature);
          }
        },
        onLongPress: isSketchPickerMode ? null : () => onFeatureLongPress(feature),
      ),
    );
  }
}
