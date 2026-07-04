import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/rollback.dart';

FeatureDto _feature(String id, {String type = 'sketch'}) =>
    FeatureDto(type: type, id: id, locked: false, produces: type == 'sketch' ? 'sketch' : 'body');

void main() {
  group('featureIdsAfter', () {
    test('returns every id after the named Feature, in order', () {
      final features = [_feature('a'), _feature('b'), _feature('c'), _feature('d')];

      expect(featureIdsAfter(features, 'b'), {'c', 'd'});
    });

    test('the last Feature has nothing after it - empty set', () {
      final features = [_feature('a'), _feature('b')];

      expect(featureIdsAfter(features, 'b'), isEmpty);
    });

    test('the first Feature returns every other Feature', () {
      final features = [_feature('a'), _feature('b'), _feature('c')];

      expect(featureIdsAfter(features, 'a'), {'b', 'c'});
    });

    test('an unknown Feature id returns an empty set rather than throwing', () {
      final features = [_feature('a'), _feature('b')];

      expect(featureIdsAfter(features, 'does-not-exist'), isEmpty);
    });

    test('a single-Feature Part always returns empty', () {
      expect(featureIdsAfter([_feature('only')], 'only'), isEmpty);
    });

    test('an empty Part returns empty for any id', () {
      expect(featureIdsAfter(const [], 'anything'), isEmpty);
    });
  });
}
