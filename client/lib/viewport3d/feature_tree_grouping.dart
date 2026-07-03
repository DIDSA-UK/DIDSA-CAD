import '../api/document_api_client.dart';

/// B3: [features] partitioned by [FeatureDto.produces] into the tree's
/// display sections - a pure function so the grouping logic itself is
/// testable in isolation without any widget/`flutter_scene` dependency,
/// the same way A2's `SelectionFilterState`/`OverrideStack` were. Purely a
/// display grouping: it never reorders [features] itself or touches the
/// dependency graph - each group's own list preserves the Features'
/// original creation/graph order (a stable partition, not a re-sort).
///
/// `"sketch"`/`"none"` (and, defensively, anything else not yet a named
/// group) all land in [other] - the existing sequential list this tree
/// already rendered before B3, unchanged. Confirmed via B1's status doc
/// that a SketchFeature really is its own dependency-graph node (not merely
/// an upstream reference from Extrude), so it stays in [other] rather than
/// being folded into [bodies].
class GroupedFeatures {
  final List<FeatureDto> bodies;
  final List<FeatureDto> planes;
  final List<FeatureDto> surfaces;
  final List<FeatureDto> other;

  const GroupedFeatures({
    required this.bodies,
    required this.planes,
    required this.surfaces,
    required this.other,
  });
}

GroupedFeatures groupFeaturesByProduces(List<FeatureDto> features) {
  final bodies = <FeatureDto>[];
  final planes = <FeatureDto>[];
  final surfaces = <FeatureDto>[];
  final other = <FeatureDto>[];

  for (final feature in features) {
    switch (feature.produces) {
      case 'body':
        bodies.add(feature);
        break;
      case 'plane':
        planes.add(feature);
        break;
      case 'surface':
        surfaces.add(feature);
        break;
      default:
        other.add(feature);
    }
  }

  return GroupedFeatures(bodies: bodies, planes: planes, surfaces: surfaces, other: other);
}
