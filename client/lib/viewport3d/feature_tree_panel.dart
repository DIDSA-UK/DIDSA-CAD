import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'feature_tree_grouping.dart';

/// The display name for the Feature at [index] in [features] - shared
/// between the tree's own rows and anything else (e.g. the cascade-delete
/// confirmation dialog) that needs to name a Feature the same way the tree
/// does, so the two never drift out of sync. Named per Feature type (e.g.
/// "Sketch 2", "Extrude 1") rather than by overall position, counting only
/// same-type Features up to and including [index].
String featureDisplayName(List<FeatureDto> features, int index) {
  final feature = features[index];
  final label = feature.type == 'extrude' ? 'Extrude' : 'Sketch';
  final ordinal = features.take(index + 1).where((f) => f.type == feature.type).length;
  return '$label $ordinal';
}

/// The visible Feature tree for a Part: one row per Feature, in creation
/// order. Locked Features (every Feature except the last) are shown greyed
/// out with a lock icon and remain tappable - a tap only selects/highlights
/// them, per the project brief - while the editable (last) Feature is
/// tappable to open it for editing. Selection is purely a display concern
/// here; [onFeatureTap] decides what a tap actually does. A long-press on
/// any row (locked or not) invokes [onFeatureLongPress] - unlike a tap,
/// this is available regardless of lock state, since the cascade-delete
/// action it can lead to also removes everything after a locked Feature
/// that depends on it.
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
                            child: Text('Features', style: TextStyle(fontWeight: FontWeight.bold)),
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

  /// B3: groups [features] by `produces` (`groupFeaturesByProduces`) into
  /// Bodies/Planes/Surfaces sections plus the pre-existing sequential
  /// "everything else" list - a display grouping only, per this prompt's
  /// own requirement: it never reorders [features] itself or the
  /// underlying dependency graph, and ordering *within* each group/the
  /// `other` list still follows [features]' own creation/graph order.
  Widget _buildGroupedTree(BuildContext context) {
    final grouped = groupFeaturesByProduces(features);
    return ListView(
      children: [
        if (grouped.bodies.isNotEmpty)
          _buildGroupSection(context, 'Bodies', Icons.view_in_ar, grouped.bodies),
        if (grouped.planes.isNotEmpty)
          _buildGroupSection(context, 'Planes', Icons.crop_din, grouped.planes),
        if (grouped.surfaces.isNotEmpty)
          _buildGroupSection(context, 'Surfaces', Icons.layers_outlined, grouped.surfaces),
        for (final feature in grouped.other) _buildFeatureTile(context, feature),
      ],
    );
  }

  /// B3: one of the tree's new `produces`-grouped sections (Bodies/Planes/
  /// Surfaces) - reuses the same [ExpansionTile] leading-icon/title
  /// convention [PartToolbar]'s File/View/Selection-Filters menus already
  /// establish, rather than inventing a new grouping widget. Starts
  /// expanded so the on-device behaviour at a glance is unchanged from
  /// before this prompt (every Feature still visible by default) - B3 adds
  /// a collapsible boundary around existing Boss/Cut rows, it doesn't hide
  /// them. Only ever built for a non-empty group (see the `isNotEmpty`
  /// guards above) - an empty group is omitted entirely rather than shown
  /// as an empty/error section, per this prompt's own requirement.
  Widget _buildGroupSection(
    BuildContext context,
    String title,
    IconData icon,
    List<FeatureDto> groupFeatures,
  ) {
    return ExpansionTile(
      initiallyExpanded: true,
      leading: Icon(icon),
      title: Text(title),
      children: [for (final feature in groupFeatures) _buildFeatureTile(context, feature)],
    );
  }

  /// One Feature's row - unchanged in behaviour/appearance from before B3,
  /// just factored out so both a grouped section and the plain "everything
  /// else" (`other`) list below it share the exact same tile. [features]
  /// (the full, ungrouped list - not whichever group [feature] happens to
  /// be rendered under) is what [featureDisplayName]'s per-type ordinal
  /// numbering ("Extrude 2") is computed against, so numbering is
  /// unaffected by which display group a Feature lands in - B3 is a
  /// display grouping only, per this prompt's own requirement, and must
  /// not change what a Feature is *called*.
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
          feature.locked ? Icons.lock : (feature.type == 'extrude' ? Icons.view_in_ar : Icons.edit),
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
