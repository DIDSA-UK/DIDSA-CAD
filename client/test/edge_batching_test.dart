import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/viewport3d/edge_batching.dart';
import 'package:didsa_cad_client/viewport3d/section_plane.dart';

void main() {
  group('worldUnitsPerPixel', () {
    test('orthographic is 2 * halfHeight / viewportHeight, whatever the distance', () {
      expect(worldUnitsPerPixel(perspective: false, viewportHeight: 800, halfHeight: 200), closeTo(0.5, 1e-12));
      expect(
        worldUnitsPerPixel(perspective: false, viewportHeight: 800, halfHeight: 200, distance: 5),
        closeTo(0.5, 1e-12),
      );
    });

    test('perspective is 2 * d * tan(fovY / 2) / viewportHeight', () {
      final fov = 60 * math.pi / 180;
      final value = worldUnitsPerPixel(perspective: true, viewportHeight: 1000, fovRadiansY: fov, distance: 500);
      expect(value, closeTo(2 * 500 * math.tan(fov / 2) / 1000, 1e-12));
      // Twice as far: twice as many world units per pixel.
      final far = worldUnitsPerPixel(perspective: true, viewportHeight: 1000, fovRadiansY: fov, distance: 1000);
      expect(far, closeTo(value * 2, 1e-12));
    });

    test('a zero-height viewport gives 0, not infinity', () {
      expect(worldUnitsPerPixel(perspective: false, viewportHeight: 0), 0);
      expect(worldUnitsPerPixel(perspective: true, viewportHeight: 0), 0);
    });

    test('edgeWorldWidth scales the pixel width', () {
      expect(edgeWorldWidth(1.4, 0.5), closeTo(0.7, 1e-12));
    });
  });

  group('nextEdgeWidth', () {
    test('the first width is always applied', () {
      expect(nextEdgeWidth(null, 0.7), 0.7);
      expect(nextEdgeWidth(0, 0.7), 0.7);
    });
    test('a change under 1 % is skipped, over 1 % is applied', () {
      expect(nextEdgeWidth(1.0, 1.005), isNull);
      expect(nextEdgeWidth(1.0, 1.02), 1.02);
      expect(nextEdgeWidth(1.0, 0.98), 0.98);
    });
    test('a non-positive desired width is ignored', () {
      expect(nextEdgeWidth(1.0, 0), isNull);
      expect(nextEdgeWidth(1.0, -1), isNull);
    });
  });

  group('depth offset', () {
    test('points from the node centre towards the camera, bias long', () {
      final offset = edgeDepthOffset(vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 10), 0.05);
      expect(offset.x, closeTo(0, 1e-6));
      expect(offset.z, closeTo(0.05, 1e-6));
      expect(offset.length, closeTo(0.05, 1e-6));
    });
    test('a node at the camera gets no offset', () {
      expect(edgeDepthOffset(vm.Vector3(1, 2, 3), vm.Vector3(1, 2, 3), 0.05).length, 0);
    });
    test('offsetTransform adds to the translation and keeps the rotation', () {
      final base = vm.Matrix4.translation(vm.Vector3(1, 2, 3))..rotateZ(0.5);
      final moved = offsetTransform(base, vm.Vector3(0.1, 0.2, 0.3));
      expect(moved.getTranslation().x, closeTo(1.1, 1e-6));
      expect(moved.getTranslation().y, closeTo(2.2, 1e-6));
      expect(moved.getTranslation().z, closeTo(3.3, 1e-6));
      for (var i = 0; i < 9; i++) {
        expect(moved.getRotation().storage[i], closeTo(base.getRotation().storage[i], 1e-6));
      }
      // The input is untouched.
      expect(base.getTranslation().x, 1);
    });
  });

  group('edge data', () {
    test('edgePositions keeps whole segments and drops a trailing partial run', () {
      final p = edgePositions([1, 2, 3, 4, 5, 6, 7, 8]);
      expect(p, Float32List.fromList([1, 2, 3, 4, 5, 6]));
      expect(edgeSegmentCount([1, 2, 3, 4, 5, 6, 7]), 1);
    });

    test('clippedEdgePositions transforms, and clips by an enabled section', () {
      final flat = <double>[0, 0, 0, 10, 0, 0];
      final moved = clippedEdgePositions(flat, vm.Matrix4.translation(vm.Vector3(0, 5, 0)), const []);
      expect(moved, Float32List.fromList([0, 5, 0, 10, 5, 0]));
      final plane = SectionPlane(
        id: 's',
        origin: vm.Vector3(4, 0, 0),
        normal: vm.Vector3(1, 0, 0),
        anchorOrigin: vm.Vector3(4, 0, 0),
      );
      final clipped = clippedEdgePositions(flat, null, [plane]);
      expect(clipped, Float32List.fromList([4, 0, 0, 10, 0, 0]));
    });

    test('sectionSignature is empty without an enabled plane and changes with the plane', () {
      final a = SectionPlane(id: 'a', origin: vm.Vector3(1, 0, 0), normal: vm.Vector3(1, 0, 0), anchorOrigin: vm.Vector3.zero());
      final off = SectionPlane(id: 'a', origin: vm.Vector3(1, 0, 0), normal: vm.Vector3(1, 0, 0), anchorOrigin: vm.Vector3.zero(), enabled: false);
      final moved = SectionPlane(id: 'a', origin: vm.Vector3(2, 0, 0), normal: vm.Vector3(1, 0, 0), anchorOrigin: vm.Vector3.zero());
      expect(sectionSignature(const []), '');
      expect(sectionSignature([off]), '');
      expect(sectionSignature([a]), isNot(sectionSignature([moved])));
      expect(sectionSignature([a]), sectionSignature([a]));
    });

    test('edgePositionsCentre is the middle of the box', () {
      final c = edgePositionsCentre(Float32List.fromList([0, 0, 0, 10, 4, 2]));
      expect([c.x, c.y, c.z], [5, 2, 1]);
      expect(edgePositionsCentre(Float32List(0)).length, 0);
    });
  });

  group('EdgeBatchCache', () {
    test('builds once per key however many times it is asked for', () {
      final cache = EdgeBatchCache<int>();
      final mesh = Object();
      var n = 0;
      const key = EdgeBatchKey(partId: 'foot', bodyId: 'b0');
      for (var instance = 0; instance < 20; instance++) {
        cache.obtain(key, mesh, () => ++n);
      }
      expect(cache.buildCount, 1);
      expect(n, 1);
    });

    test('a camera-only change (the same keys and meshes again) rebuilds nothing', () {
      final cache = EdgeBatchCache<int>();
      final meshes = {for (var i = 0; i < 5; i++) 'b$i': Object()};
      void pass() {
        cache.beginPass();
        for (final e in meshes.entries) {
          cache.obtain(EdgeBatchKey(partId: 'p', bodyId: e.key), e.value, () => 1);
        }
        cache.endPass();
      }

      pass();
      expect(cache.buildCount, 5);
      pass();
      pass();
      expect(cache.buildCount, 5);
    });

    test('a new mesh object, a new section, or a new body rebuilds that entry only', () {
      final cache = EdgeBatchCache<int>();
      final a = Object();
      final b = Object();
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'a'), a, () => 1);
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'b'), b, () => 1);
      expect(cache.buildCount, 2);
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'a'), Object(), () => 1); // mesh replaced
      expect(cache.buildCount, 3);
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'b', sectionSignature: 's1'), b, () => 1); // section on
      expect(cache.buildCount, 4);
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'b', sectionSignature: 's1'), b, () => 1);
      expect(cache.buildCount, 4);
    });

    test('endPass evicts what the pass did not use, and reports it', () {
      final evicted = <int>[];
      final cache = EdgeBatchCache<int>(onEvict: evicted.add);
      final m = Object();
      cache.beginPass();
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'a'), m, () => 1);
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'b'), m, () => 2);
      cache.endPass();
      cache.beginPass();
      cache.obtain(const EdgeBatchKey(partId: 'p', bodyId: 'a'), m, () => 1);
      cache.endPass();
      expect(cache.length, 1);
      expect(evicted, [2]);
      cache.clear();
      expect(cache.length, 0);
    });

    test('platform fixture numbers: 133 bodies / 11,918 segments is 133 geometries, not 11,918', () {
      // The owner's platform (docs/assembly-perf-mates-and-ui-plan.md, Part A): 133 bodies, 11,918 edge segments.
      // Per-segment primitives were the crash; the batched form is one geometry per body, and instancing the same
      // Part (e.g. 20 foot pads) must not add any.
      const bodies = 133;
      const totalSegments = 11918;
      final perBody = [for (var i = 0; i < bodies; i++) totalSegments ~/ bodies + (i < totalSegments % bodies ? 1 : 0)];
      expect(perBody.reduce((a, b) => a + b), totalSegments);
      final cache = EdgeBatchCache<Float32List>();
      final meshes = [for (var i = 0; i < bodies; i++) Object()];
      var nodes = 0;
      for (var pass = 0; pass < 3; pass++) {
        cache.beginPass();
        for (var instance = 0; instance < 3; instance++) {
          for (var i = 0; i < bodies; i++) {
            cache.obtain(EdgeBatchKey(partId: 'part$i', bodyId: 'b'), meshes[i], () => Float32List(perBody[i] * 6));
            nodes++;
          }
        }
        cache.endPass();
      }
      expect(cache.buildCount, bodies);
      expect(cache.length, bodies);
      expect(nodes, bodies * 9);
    });
  });
}
