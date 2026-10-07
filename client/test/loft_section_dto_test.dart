import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';

void main() {
  group('LoftSectionDto', () {
    test('round-trips seam and reverse, and omits them when automatic', () {
      const section = LoftSectionDto(sketchFeatureId: 'sk1', seamParam: 0.25, reverse: true);
      final json = section.toJson();
      expect(json['seam_param'], 0.25);
      expect(json['reverse'], true);
      final back = LoftSectionDto.fromJson(json);
      expect(back.seamParam, 0.25);
      expect(back.reverse, isTrue);

      final plain = const LoftSectionDto(sketchFeatureId: 'sk1').toJson();
      expect(plain.containsKey('seam_param'), isFalse);
      expect(plain.containsKey('reverse'), isFalse);
    });

    test('an edge-based section parses and round-trips instead of failing on the missing sketch id', () {
      final json = {
        'edge_ref': {'body_id': 'b1', 'kind': 'edge', 'index': 3},
        'profile_refs': <dynamic>[],
      };
      final section = LoftSectionDto.fromJson(json);
      expect(section.sketchFeatureId, isEmpty);
      final out = section.toJson();
      expect(out.containsKey('sketch_feature_id'), isFalse);
      expect(out['edge_ref'], json['edge_ref']);
    });

    test('withAlignment replaces only the alignment fields', () {
      final stored = LoftSectionDto.fromJson({
        'sketch_feature_id': 'sk1',
        'profile_refs': [
          {'sketch_id': 's', 'entity_type': 'line', 'entity_id': 'l1'},
        ],
        'reference_point': {'sketch_id': 's', 'entity_type': 'point', 'entity_id': 'p1'},
      });
      final edited = stored.withAlignment(alignmentPoint: null, seamParam: 0.5, reverse: true);
      expect(edited.profileRefs, hasLength(1));
      expect(edited.referencePoint?.entityId, 'p1');
      expect(edited.seamParam, 0.5);
      expect(edited.reverse, isTrue);
    });
  });
}
