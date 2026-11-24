import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_helpers.dart';

// What the build tree's rows share with the rest of the client (moved from the old panel and its tests in P3 of
// docs/assembly-tree-overhaul-scope.md): feature names, icons, lost-reference text, the edit-panel and coarse-pin rules.

FeatureDto _feature(String type, String id, {String? operation}) =>
    FeatureDto(type: type, id: id, locked: false, produces: 'body', operation: operation);

void main() {
  test('featureDisplayName labels every gear-family type with its own design-screen vocabulary', () {
    final features = [
      _feature('gear', 'f1'),
      _feature('rack', 'f2'),
      _feature('gear_chain', 'f3'),
      _feature('planetary_gear', 'f4'),
      _feature('bevel_gear', 'f5'),
      _feature('bevel_pair', 'f6'),
    ];
    expect([for (var i = 0; i < features.length; i++) featureDisplayName(features, i)],
        ['Gear 1', 'Rack 1', 'Gear Chain 1', 'Planetary Gear 1', 'Bevel Gear 1', 'Bevel Pair 1']);
  });

  test('featureDisplayName labels a boolean by its operation, counting both operations together', () {
    final features = [_feature('boolean', 'f1', operation: 'subtract'), _feature('boolean', 'f2', operation: 'common')];
    expect(featureDisplayName(features, 0), 'Subtract 1');
    expect(featureDisplayName(features, 1), 'Common 2');
  });

  test('featureDisplayName counts per type ("Sketch 2", "Extrude 1")', () {
    final features = [_feature('sketch', 's1'), _feature('extrude', 'e1'), _feature('sketch', 's2')];
    expect(featureDisplayName(features, 2), 'Sketch 2');
    expect(featureDisplayName(features, 1), 'Extrude 1');
  });

  test('every gear-family type shares the gear icon, and a boolean the Merge icon (not the Sketch fallback)', () {
    for (final type in ['gear', 'rack', 'gear_chain', 'planetary_gear', 'bevel_gear', 'bevel_pair']) {
      expect(assemblyTreeFeatureAsset(type), 'assets/icons/feature/feature_gear.svg', reason: type);
    }
    expect(assemblyTreeFeatureAsset('boolean'), 'assets/icons/feature/feature_merge.svg');
    expect(assemblyTreeFeatureAsset('curve', curveType: 'intersection'), 'assets/icons/feature/feature_intersection_curve.svg');
    expect(assemblyTreeFeatureAsset('something new'), 'assets/icons/feature/feature_new_sketch.svg');
  });

  test('a lost reference says how many and how to fix it: a sketch re-attaches, any other feature re-selects', () {
    FeatureDto sketch(List<String> points) => FeatureDto.fromJson({
          'type': 'sketch',
          'id': 's1',
          'sketch_id': 'sk1',
          'locked': false,
          'produces': 'none',
          'has_lost_reference': true,
          'lost_reference_point_ids': points,
        });
    FeatureDto fillet(List<String> refs) => FeatureDto.fromJson({
          'type': 'fillet',
          'id': 'f1',
          'locked': false,
          'produces': 'body',
          'radius': 2.0,
          'has_lost_reference': true,
          'lost_references': refs,
        });
    expect(lostReferenceReason(sketch(['a', 'b'])), '2 lost - open to re-attach');
    expect(lostReferenceReason(sketch(['a'])), 'open to re-attach');
    expect(lostReferenceReason(fillet(['edge_refs[0]', 'edge_refs[1]'])), '2 lost - open to re-select');
    expect(lostReferenceReason(fillet(const [])), 'open to re-select');
  });

  test('an import and a Fill Surface have no edit panel; pin to coarse is for the coarse-eligible types only', () {
    expect(featureTypeHasEditPanel('import'), isFalse);
    expect(featureTypeHasEditPanel('fill_surface'), isFalse);
    expect(featureTypeHasEditPanel('extrude'), isTrue);
    expect(kCoarseEligibleFeatureTypes, containsAll(['gear', 'pattern', 'loft']));
    expect(kCoarseEligibleFeatureTypes.contains('extrude'), isFalse);
  });
}
