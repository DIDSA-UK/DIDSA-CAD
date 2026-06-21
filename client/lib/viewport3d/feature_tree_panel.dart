import 'package:flutter/material.dart';

import '../api/document_api_client.dart';

/// The visible Feature tree for a Part: one row per Feature, in creation
/// order. Locked Features (every Feature except the last) are shown greyed
/// out with a lock icon and remain tappable - a tap only selects/highlights
/// them, per the project brief - while the editable (last) Feature is
/// tappable to open it for editing. Selection is purely a display concern
/// here; [onFeatureTap] decides what a tap actually does.
class FeatureTreePanel extends StatelessWidget {
  final List<FeatureDto> features;
  final String? selectedFeatureId;
  final void Function(FeatureDto feature) onFeatureTap;

  const FeatureTreePanel({
    super.key,
    required this.features,
    required this.selectedFeatureId,
    required this.onFeatureTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      elevation: 2,
      child: SizedBox(
        width: 220,
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
              title: Text('Sketch ${index + 1}'),
              subtitle: Text(feature.locked ? 'Locked' : 'Editable'),
              onTap: () => onFeatureTap(feature),
            );
          },
        ),
      ),
    );
  }
}
