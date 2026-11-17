import '../api/document_api_client.dart';

/// What a Pattern is seeded from, decided in ONE place for every way of starting the tool (Start > Pattern, the selection drawer's Pattern on bodies, a
/// long press on a feature in the Build tree > Pattern, "Select Feature" / "Add from Tree" inside the tool).
///
/// The backend has two ways to repeat a feature: `source_feature_ids` copies the BODIES a feature made (an extrude that started a body), and
/// `tool_feature_ids` repeats the feature itself into the body it acts on (a cut, or a boss merged into an existing body - there is no body of its own to
/// copy). So a picked feature goes to whichever of the two it qualifies for, whichever way it was picked, and a cut can be patterned from Start exactly as
/// from the long press. Bodies and tool features cannot be mixed in one pattern (a tool-feature pattern has the single target it cuts, `merge` is
/// forced to fuse): [error] says so.
class PatternSeed {
  final List<String> bodyIds;
  final List<String> sourceFeatureIds;
  final List<String> toolFeatureIds;

  /// Set when the picks cannot make one pattern; the seed lists above are then empty.
  final String? error;

  const PatternSeed({this.bodyIds = const [], this.sourceFeatureIds = const [], this.toolFeatureIds = const [], this.error});

  bool get isToolFeatureSeed => toolFeatureIds.isNotEmpty;
  bool get isEmpty => bodyIds.isEmpty && sourceFeatureIds.isEmpty && toolFeatureIds.isEmpty;
}

/// [isToolFeature] says whether a feature can be repeated as a tool (a cut, or a boss into a target body); everything else picked is a body-making
/// feature copied through `source_feature_ids`. Order of [features] is kept.
PatternSeed resolvePatternSeed({
  required List<String> bodyIds,
  required List<FeatureDto> features,
  required bool Function(FeatureDto) isToolFeature,
}) {
  final tools = [for (final f in features) if (isToolFeature(f)) f.id];
  final sources = [for (final f in features) if (!isToolFeature(f)) f.id];
  if (tools.isNotEmpty && (bodyIds.isNotEmpty || sources.isNotEmpty)) {
    return const PatternSeed(
      error: 'Cut features and bodies can\'t be patterned together. Pick the cuts on their own, or the bodies (and features that made them) on their own.',
    );
  }
  return PatternSeed(bodyIds: List.of(bodyIds), sourceFeatureIds: sources, toolFeatureIds: tools);
}
