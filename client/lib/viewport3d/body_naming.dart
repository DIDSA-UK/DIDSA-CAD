import '../api/document_api_client.dart';

/// B3 revision (on-device feedback): stable "Body 1"/"Body 2"... display
/// names for a Part's currently-computed Bodies - shared between the
/// feature tree's "Bodies" section and [SelectionListDrawer], so the same
/// Body is called the same thing everywhere rather than each place
/// inventing its own scheme (the previous per-widget "first 8 characters
/// of body_id" truncation in [SelectionListDrawer] is what produced two
/// identically-labelled "Body 8adb4187" rows for a split Body on-device -
/// the shared `#N` split suffix a truncation that short never reaches).
///
/// [bodyIds] are ordered by which Feature created them (their index in
/// [features], not the id string itself, which is opaque) and, for a
/// Feature that split into more than one Body (A1's amendment - a Boss
/// over a multi-profile Sketch, or a severing Cut - see
/// backend `app.document.extrude._register_solids`/`base_feature_id`), by
/// the `#N` split-index suffix. Numbering is per-Part, not per-Feature -
/// "Body 1"/"Body 2" continue counting up across every Feature that
/// produced a Body, in that order, the same way [featureDisplayName]
/// counts same-type Features up rather than restarting per Feature.
Map<String, String> bodyDisplayNames(List<FeatureDto> features, List<String> bodyIds) {
  final featureIndex = <String, int>{for (var i = 0; i < features.length; i++) features[i].id: i};

  final sorted = [...bodyIds]
    ..sort((a, b) {
      final indexA = featureIndex[_baseFeatureId(a)] ?? features.length;
      final indexB = featureIndex[_baseFeatureId(b)] ?? features.length;
      if (indexA != indexB) return indexA.compareTo(indexB);
      return _splitIndex(a).compareTo(_splitIndex(b));
    });

  return {for (var i = 0; i < sorted.length; i++) sorted[i]: 'Body ${i + 1}'};
}

/// Mirrors backend `app.document.extrude.base_feature_id`: strips a `#N`
/// split-index suffix to resolve a composite Body id back to the Feature
/// id that created it. A plain, unsuffixed body_id is returned unchanged.
String _baseFeatureId(String bodyId) {
  final hashIndex = bodyId.indexOf('#');
  return hashIndex == -1 ? bodyId : bodyId.substring(0, hashIndex);
}

/// The `#N` split-index suffix itself (0 for a plain, unsuffixed body_id -
/// the common single-solid case, which always sorts first among any
/// composite siblings from the same Feature since a real split index is
/// never negative).
int _splitIndex(String bodyId) {
  final hashIndex = bodyId.indexOf('#');
  if (hashIndex == -1) return 0;
  return int.tryParse(bodyId.substring(hashIndex + 1)) ?? 0;
}
