import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/sketch/sketch_canvas.dart' show closedGhostLoops;

typedef _P = (double, double);
typedef _Seg = (_P, _P);

void main() {
  group('closedGhostLoops', () {
    test('empty input finds no loops', () {
      expect(closedGhostLoops(const []), isEmpty);
    });

    test('four segments forming a closed square are recovered as one loop', () {
      const a = (0.0, 0.0);
      const b = (10.0, 0.0);
      const c = (10.0, 10.0);
      const d = (0.0, 10.0);
      final segments = <_Seg>[(a, b), (b, c), (c, d), (d, a)];

      final loops = closedGhostLoops(segments);

      expect(loops, hasLength(1));
      expect(loops.single, hasLength(4));
      expect(loops.single.toSet(), {a, b, c, d});
    });

    test('a closed triangle (the minimum possible loop) is recovered', () {
      const a = (0.0, 0.0);
      const b = (10.0, 0.0);
      const c = (5.0, 10.0);
      final segments = <_Seg>[(a, b), (b, c), (c, a)];

      final loops = closedGhostLoops(segments);

      expect(loops, hasLength(1));
      expect(loops.single, hasLength(3));
    });

    test('an open chain (never closes back on itself) finds no loop', () {
      const a = (0.0, 0.0);
      const b = (10.0, 0.0);
      const c = (10.0, 10.0);
      const d = (0.0, 20.0); // doesn't connect back to a
      final segments = <_Seg>[(a, b), (b, c), (c, d)];

      expect(closedGhostLoops(segments), isEmpty);
    });

    test('endpoints that are numerically close but not byte-identical still snap-merge '
        'into the same node', () {
      const a = (0.0, 0.0);
      const b = (10.0, 0.0);
      const c = (10.0, 10.0);
      const d = (0.0, 10.0);
      // Each edge's own two endpoints are exact, but the corner it shares
      // with the *next* edge is expressed with a tiny float wobble - the
      // same kind of drift a real mesh-edge projection can leave between
      // two triangles that conceptually share a vertex.
      final segments = <_Seg>[
        (a, (10.0000001, 0.0000001)), // A -> B~
        (b, (10.0000001, 10.0000001)), // B -> C~
        (c, (0.0000001, 10.0000001)), // C -> D~
        (d, (0.0000001, 0.0000001)), // D -> A~
      ];

      final loops = closedGhostLoops(segments);

      expect(loops, hasLength(1));
      expect(loops.single, hasLength(4));
    });

    test('two disjoint closed squares are recovered as two independent loops', () {
      const a1 = (0.0, 0.0);
      const b1 = (10.0, 0.0);
      const c1 = (10.0, 10.0);
      const d1 = (0.0, 10.0);
      const a2 = (100.0, 100.0);
      const b2 = (110.0, 100.0);
      const c2 = (110.0, 110.0);
      const d2 = (100.0, 110.0);
      final segments = <_Seg>[
        (a1, b1), (b1, c1), (c1, d1), (d1, a1),
        (a2, b2), (b2, c2), (c2, d2), (d2, a2),
      ];

      final loops = closedGhostLoops(segments);

      expect(loops, hasLength(2));
      // Set == is identity-based in Dart, not content-based - compare via
      // containsAll (element-wise, and records like (double, double) do have
      // real structural ==) instead of Set-to-Set equality.
      bool hasExactly(Set<_P> expected) =>
          loops.any((loop) => loop.length == expected.length && loop.toSet().containsAll(expected));
      expect(hasExactly({a1, b1, c1, d1}), isTrue);
      expect(hasExactly({a2, b2, c2, d2}), isTrue);
    });

    test('a stray edge touching one corner of an otherwise-closed square (a T-junction) '
        'excludes that loop rather than filling it wrong (v1 scope: no junction-aware '
        'planar-face splitting)', () {
      const a = (0.0, 0.0);
      const b = (10.0, 0.0);
      const c = (10.0, 10.0);
      const d = (0.0, 10.0);
      const strayEnd = (5.0, -5.0);
      final segments = <_Seg>[
        (a, b),
        (b, c),
        (c, d),
        (d, a),
        (a, strayEnd), // makes node `a` degree 3, not 2
      ];

      expect(closedGhostLoops(segments), isEmpty);
    });

    test('a zero-length segment (both endpoints coincide after snapping) is ignored, not '
        'treated as a degenerate loop', () {
      const a = (0.0, 0.0);
      final segments = <_Seg>[(a, a)];

      expect(closedGhostLoops(segments), isEmpty);
    });
  });
}
