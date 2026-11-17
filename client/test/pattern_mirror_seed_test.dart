import 'package:flutter_test/flutter_test.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/pattern_mirror_seed.dart';

FeatureDto _f(String id, {required bool tool}) => FeatureDto(type: 'extrude', id: id, locked: false, produces: 'body', extrudeType: tool ? 'cut' : 'boss');

bool _isTool(FeatureDto f) => f.extrudeType == 'cut';

void main() {
  group('resolveSeed: one rule for Pattern and Mirror, from Start, the selection drawer, a long press or Select Feature', () {
    test('a cut is repeated as a tool, from Start exactly as from a long press', () {
      final cut = _f('cut1', tool: true);
      final fromLongPress = resolveSeed(bodyIds: const [], features: [cut], isToolFeature: _isTool);
      final fromStart = resolveSeed(bodyIds: const [], features: [cut], isToolFeature: _isTool);
      expect(fromStart.toolFeatureIds, ['cut1']);
      expect(fromStart.sourceFeatureIds, isEmpty);
      expect(fromStart.bodyIds, isEmpty);
      expect(fromStart.toolFeatureIds, fromLongPress.toolFeatureIds);
      expect(fromStart.isToolFeatureSeed, isTrue);
      expect(fromStart.error, isNull);
    });

    test('several cuts are patterned together', () {
      final seed = resolveSeed(bodyIds: const [], features: [_f('a', tool: true), _f('b', tool: true)], isToolFeature: _isTool);
      expect(seed.toolFeatureIds, ['a', 'b']);
      expect(seed.error, isNull);
    });

    test('a feature that made a body is copied through source_feature_ids', () {
      final seed = resolveSeed(bodyIds: const ['body1'], features: [_f('boss', tool: false)], isToolFeature: _isTool);
      expect(seed.bodyIds, ['body1']);
      expect(seed.sourceFeatureIds, ['boss']);
      expect(seed.toolFeatureIds, isEmpty);
      expect(seed.error, isNull);
    });

    test('cuts and bodies cannot be mixed: a message, and nothing seeded', () {
      final withBody = resolveSeed(bodyIds: const ['body1'], features: [_f('cut1', tool: true)], isToolFeature: _isTool);
      final withBoss = resolveSeed(bodyIds: const [], features: [_f('cut1', tool: true), _f('boss', tool: false)], isToolFeature: _isTool);
      for (final seed in [withBody, withBoss]) {
        expect(seed.error, isNotNull);
        expect(seed.isEmpty, isTrue);
      }
    });

    test('nothing picked is an empty seed, not an error', () {
      final seed = resolveSeed(bodyIds: const [], features: const [], isToolFeature: _isTool);
      expect(seed.isEmpty, isTrue);
      expect(seed.error, isNull);
    });
  });

  group('FeatureDto.toolFeatureIds', () {
    test('reads the list, falls back to the single id from an older backend, and is empty otherwise', () {
      Map<String, dynamic> json(Map<String, dynamic> extra) => {'type': 'pattern', 'id': 'p', 'locked': false, 'produces': 'body', ...extra};
      expect(FeatureDto.fromJson(json({'tool_feature_id': 'a', 'tool_feature_ids': ['a', 'b']})).toolFeatureIds, ['a', 'b']);
      expect(FeatureDto.fromJson(json({'tool_feature_id': 'a'})).toolFeatureIds, ['a']);
      expect(FeatureDto.fromJson(json({})).toolFeatureIds, isEmpty);
    });
  });
}
