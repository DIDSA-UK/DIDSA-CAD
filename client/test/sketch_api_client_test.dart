import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';

void main() {
  group('ProfileDetectionDto.fromJson', () {
    test('a single closed_loop with a hole becomes one fillableLoop with one innerLoop', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'closed_loop',
        'detail': 'ok',
        'profile': {
          'point_ids': ['a', 'b', 'c', 'd'],
          'line_ids': ['l1', 'l2', 'l3', 'l4'],
          'inner_loops': [
            {
              'point_ids': ['e', 'f', 'g', 'h'],
              'line_ids': ['l5', 'l6', 'l7', 'l8'],
              'inner_loops': <Map<String, dynamic>>[],
            },
          ],
        },
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      });

      expect(dto.isClosedLoop, isTrue);
      expect(dto.isExtrudable, isTrue);
      expect(dto.fillableLoops, hasLength(1));
      expect(dto.fillableLoops.single.pointIds, ['a', 'b', 'c', 'd']);
      expect(dto.fillableLoops.single.innerLoops, hasLength(1));
      expect(dto.fillableLoops.single.innerLoops.single.pointIds, ['e', 'f', 'g', 'h']);
    });

    test('a MultiProfile (multiple_loops) becomes one fillableLoop per outer loop', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'multiple_loops',
        'detail': '2 disjoint outer profiles found in this sketch.',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': [
          {
            'point_ids': ['a', 'b', 'c', 'd'],
            'line_ids': ['l1', 'l2', 'l3', 'l4'],
            'inner_loops': [
              {
                'point_ids': ['e', 'f', 'g', 'h'],
                'line_ids': ['l5', 'l6', 'l7', 'l8'],
                'inner_loops': <Map<String, dynamic>>[],
              },
            ],
          },
          {
            'point_ids': ['i', 'j', 'k'],
            'line_ids': ['l9', 'l10', 'l11'],
            'inner_loops': <Map<String, dynamic>>[],
          },
        ],
      });

      expect(dto.isClosedLoop, isFalse);
      expect(dto.isExtrudable, isTrue);
      expect(dto.fillableLoops, hasLength(2));
      expect(dto.fillableLoops[0].innerLoops, hasLength(1));
      expect(dto.fillableLoops[1].innerLoops, isEmpty);
    });

    test('a status with no usable profile has no fillableLoops', () {
      final dto = ProfileDetectionDto.fromJson({
        'status': 'no_loop',
        'detail': 'Sketch has no connectable entities (e.g. lines or circles).',
        'profile': null,
        'branch_point_ids': <String>[],
        'loops': <Map<String, dynamic>>[],
      });

      expect(dto.isExtrudable, isFalse);
      expect(dto.fillableLoops, isEmpty);
    });
  });
}
