import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

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
                    Expanded(
                      child: ListView.builder(
                        itemCount: features.length,
                        itemBuilder: (context, index) {
                          final feature = features[index];
                          final selected = feature.id == selectedFeatureId;
                          final hidden = hiddenFeatureIds.contains(feature.id);
                          final isSketch = feature.type == 'sketch';
                          // Dimmed (but still tappable - an ineligible tap
                          // surfaces a SnackBar via onSketchPicked rather
                          // than being inert) whenever picking and this row
                          // isn't a Sketch with a known-closed profile.
                          final pickerDimmed = isSketchPickerMode && (!isSketch || !pickableSketchIds.contains(feature.id));
                          return Opacity(
                            opacity: hidden || pickerDimmed ? 0.5 : 1.0,
                            child: ListTile(
                              selected: selected,
                              leading: Icon(
                                feature.locked
                                    ? Icons.lock
                                    : (feature.type == 'extrude' ? Icons.view_in_ar : Icons.edit),
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
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
