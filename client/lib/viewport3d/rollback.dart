import '../api/document_api_client.dart';

/// B4: every Feature id positioned strictly after [featureId] in [features]
/// - what true-rollback editing suppresses from the viewport (via
/// `PartScreen._beginRollback`, which merges this into `hidden_feature_ids`)
/// while the named Feature (or an earlier one) is being edited. Pulled out
/// as a pure, zero-Flutter-dependency function - like `feature_tree_panel
/// .dart`'s `featureDisplayName` - so this prompt's actual scope-selection
/// logic is genuinely unit-testable in isolation from `PartScreen` itself,
/// which can't be widget-tested in this sandbox (`flutter_scene`).
///
/// Empty whenever [featureId] is already the last Feature (or isn't found
/// at all) - nothing after it to roll back from, so the caller can treat an
/// empty result as "skip rollback, this is today's already-supported
/// edit-the-last-Feature case" without a separate check.
Set<String> featureIdsAfter(List<FeatureDto> features, String featureId) {
  final index = features.indexWhere((f) => f.id == featureId);
  if (index == -1) return {};
  return features.skip(index + 1).map((f) => f.id).toSet();
}
