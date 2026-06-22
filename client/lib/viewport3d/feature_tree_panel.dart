import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// The display name for the Feature at [index] in a Part's ordered Feature
/// list - shared between the tree's own rows and anything else (e.g. the
/// cascade-delete confirmation dialog) that needs to name a Feature the
/// same way the tree does, so the two never drift out of sync.
String featureDisplayName(int index) => 'Sketch ${index + 1}';

/// The visible Feature tree for a Part: one row per Feature, in creation
/// order. Locked Features (every Feature except the last) are shown greyed
/// out with a lock icon and remain tappable - a tap only selects/highlights
/// them, per the project brief - while the editable (last) Feature is
/// tappable to open it for editing. Selection is purely a display concern
/// here; [onFeatureTap] decides what a tap actually does. A long-press on
/// any row (locked or not) triggers the cascade-delete flow via
/// [onFeatureLongPress] - unlike a tap, this is available regardless of
/// lock state, since cascade-deleting a locked Feature also removes
/// everything after it that depends on it.
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

  const FeatureTreePanel({
    super.key,
    required this.visible,
    required this.features,
    required this.selectedFeatureId,
    required this.onFeatureTap,
    required this.onFeatureLongPress,
    required this.onClose,
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
                    Expanded(
                      child: ListView.builder(
                        itemCount: features.length,
                        itemBuilder: (context, index) {
                          final feature = features[index];
                          final selected = feature.id == selectedFeatureId;
                          return ListTile(
                            selected: selected,
                            leading: Icon(
                              feature.locked ? Icons.lock : Icons.edit,
                              color: feature.locked ? Colors.grey : Theme.of(context).colorScheme.primary,
                            ),
                            title: Text(featureDisplayName(index)),
                            subtitle: Text(feature.locked ? 'Locked' : 'Editable'),
                            onTap: () => onFeatureTap(feature),
                            onLongPress: () => onFeatureLongPress(feature),
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
