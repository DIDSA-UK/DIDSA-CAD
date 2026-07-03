import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/feature_tree_grouping.dart';

FeatureDto _feature(String id, String produces, {String type = 'extrude'}) {
  return FeatureDto(type: type, id: id, locked: false, produces: produces);
}

void main() {
  group('groupFeaturesByProduces', () {
    test('an empty feature list produces four empty groups', () {
      final grouped = groupFeaturesByProduces(const []);

      expect(grouped.bodies, isEmpty);
      expect(grouped.planes, isEmpty);
      expect(grouped.surfaces, isEmpty);
      expect(grouped.other, isEmpty);
    });

    test('partitions body/plane/surface into their own groups', () {
      final body = _feature('f1', 'body');
      final plane = _feature('f2', 'plane');
      final surface = _feature('f3', 'surface');

      final grouped = groupFeaturesByProduces([body, plane, surface]);

      expect(grouped.bodies, [body]);
      expect(grouped.planes, [plane]);
      expect(grouped.surfaces, [surface]);
      expect(grouped.other, isEmpty);
    });

    test('sketch and none both land in the existing sequential "other" list', () {
      final sketch = _feature('f1', 'sketch', type: 'sketch');
      final none = _feature('f2', 'none');

      final grouped = groupFeaturesByProduces([sketch, none]);

      expect(grouped.other, [sketch, none]);
      expect(grouped.bodies, isEmpty);
      expect(grouped.planes, isEmpty);
      expect(grouped.surfaces, isEmpty);
    });

    test('an unrecognized produces value falls back to "other" rather than being dropped', () {
      final mystery = _feature('f1', 'something-a-future-prompt-invents');

      final grouped = groupFeaturesByProduces([mystery]);

      expect(grouped.other, [mystery]);
    });

    test('preserves each group\'s own creation order - a stable partition, not a re-sort', () {
      final sketch = _feature('sketch-1', 'sketch', type: 'sketch');
      final bodyA = _feature('body-a', 'body');
      final sketch2 = _feature('sketch-2', 'sketch', type: 'sketch');
      final bodyB = _feature('body-b', 'body');

      final grouped = groupFeaturesByProduces([sketch, bodyA, sketch2, bodyB]);

      expect(grouped.bodies, [bodyA, bodyB]);
      expect(grouped.other, [sketch, sketch2]);
    });

    test(
      'multiple Extrude Features producing multiple Bodies each still contribute exactly one '
      'tree node per Feature, not per Body - grouping is over Features, never Bodies',
      () {
        // A single ExtrudeFeature can already produce more than one Body
        // (A1/A3's disjoint-solids splitting) - groupFeaturesByProduces has
        // no visibility into that at all, since it only ever sees Features,
        // confirming a multi-body Feature can't accidentally be duplicated
        // into multiple tree rows by this function.
        final multiBodyExtrude = _feature('boss-1', 'body');

        final grouped = groupFeaturesByProduces([multiBodyExtrude]);

        expect(grouped.bodies, [multiBodyExtrude]);
        expect(grouped.bodies.length, 1);
      },
    );

    test('a realistic mixed Part groups correctly end to end', () {
      final sketch1 = _feature('sketch-1', 'sketch', type: 'sketch');
      final boss = _feature('boss', 'body');
      final sketch2 = _feature('sketch-2', 'sketch', type: 'sketch');
      final cut = _feature('cut', 'body');

      final grouped = groupFeaturesByProduces([sketch1, boss, sketch2, cut]);

      expect(grouped.bodies, [boss, cut]);
      expect(grouped.planes, isEmpty);
      expect(grouped.surfaces, isEmpty);
      expect(grouped.other, [sketch1, sketch2]);
    });
  });
}
