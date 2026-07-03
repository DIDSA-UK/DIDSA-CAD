import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/body_naming.dart';

FeatureDto _feature(String id, {String type = 'extrude'}) =>
    FeatureDto(type: type, id: id, locked: false, produces: type == 'sketch' ? 'sketch' : 'body');

void main() {
  group('bodyDisplayNames', () {
    test('an empty body id list produces an empty map', () {
      expect(bodyDisplayNames([_feature('f1')], const []), isEmpty);
    });

    test('numbers Bodies in Feature creation order, not body_id string order', () {
      final features = [_feature('boss-z'), _feature('boss-a')];
      // 'boss-z' was created first (index 0) despite sorting alphabetically
      // after 'boss-a' - names must follow creation order, not string order.
      final names = bodyDisplayNames(features, ['boss-a', 'boss-z']);

      expect(names['boss-z'], 'Body 1');
      expect(names['boss-a'], 'Body 2');
    });

    test('a Feature split into multiple Bodies numbers by split index, in order', () {
      final features = [_feature('boss-1')];
      final names = bodyDisplayNames(features, ['boss-1#1', 'boss-1#0']);

      expect(names['boss-1#0'], 'Body 1');
      expect(names['boss-1#1'], 'Body 2');
    });

    test('an unsplit body_id sorts before any split sibling from a later Feature', () {
      final features = [_feature('boss-1'), _feature('boss-2')];
      final names = bodyDisplayNames(features, ['boss-2#0', 'boss-1', 'boss-2#1']);

      expect(names['boss-1'], 'Body 1');
      expect(names['boss-2#0'], 'Body 2');
      expect(names['boss-2#1'], 'Body 3');
    });

    test('two split Bodies from the on-device screenshot scenario get distinct names', () {
      // Regression case: a single multi-profile Boss split into two Bodies
      // sharing the same base id, previously both displaying as the
      // identical truncated "Body 8adb4187" in SelectionListDrawer.
      final features = [_feature('8adb4187-aaaa-bbbb-cccc-000000000000')];
      final bodyIds = [
        '8adb4187-aaaa-bbbb-cccc-000000000000#0',
        '8adb4187-aaaa-bbbb-cccc-000000000000#1',
      ];

      final names = bodyDisplayNames(features, bodyIds);

      expect(names[bodyIds[0]], 'Body 1');
      expect(names[bodyIds[1]], 'Body 2');
      expect(names[bodyIds[0]], isNot(names[bodyIds[1]]));
    });

    test('a body_id with no matching Feature (defensive) still gets a name, sorted last', () {
      final features = [_feature('boss-1')];
      final names = bodyDisplayNames(features, ['boss-1', 'does-not-exist']);

      expect(names['boss-1'], 'Body 1');
      expect(names['does-not-exist'], 'Body 2');
    });
  });
}
