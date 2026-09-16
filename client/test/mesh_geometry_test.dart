import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/mesh_geometry.dart';

void main() {
  test('meshBuffersFromMesh packs position/normal/uv/color into 12 floats per vertex', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh);

    expect(buffers.vertexCount, 3);
    expect(buffers.vertexData.length, 3 * 12);

    final vertex1 = buffers.vertexData.sublist(12, 24);
    expect(vertex1, [
      1, 0, 0, // position
      0, 0, 1, // normal
      0, 0, // uv
      1, 1, 1, 1, // color
    ]);
  });

  test('meshBuffersFromMesh writes a flat 32-bit index buffer from triangleIndices', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
        [1, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
        [2, 1, 3],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh);
    final indices = Uint32List.sublistView(buffers.indexData);

    expect(indices, [0, 1, 2, 2, 1, 3]);
  });

  test(
      'meshBuffersFromMesh survives a vertex index past the old 16-bit ceiling - '
      'regression guard for the Uint16 index-wraparound bug (a dense mesh - e.g. '
      'several concentric curved bands with internal ribs - rendered as a garbled, '
      'self-intersecting mess in the 3D viewport while the exact same tessellation '
      'exported to glTF looked correct, because indices above 65535 silently wrapped '
      'mod 65536 instead of pointing at the real vertex)', () {
    // One triangle whose own vertex data sits harmlessly near the origin, but
    // whose *index* into a much larger vertex list is deliberately placed
    // just past the old Uint16 ceiling - only the index buffer's own dtype
    // matters for this bug, not how many vertices are actually populated.
    const overflowIndex = 70000;
    final vertices = List.generate(
      overflowIndex + 3,
      (i) => i == overflowIndex
          ? [0.0, 0.0, 0.0]
          : i == overflowIndex + 1
              ? [1.0, 0.0, 0.0]
              : i == overflowIndex + 2
                  ? [0.0, 1.0, 0.0]
                  : [0.0, 0.0, 0.0],
    );
    final normals = List.generate(vertices.length, (_) => [0.0, 0.0, 1.0]);
    final mesh = MeshDto(
      vertices: vertices,
      normals: normals,
      triangleIndices: [
        [overflowIndex, overflowIndex + 1, overflowIndex + 2],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh);
    final indices = Uint32List.sublistView(buffers.indexData);

    // A Uint16-backed index buffer would have wrapped these to
    // [70000 - 65536, 70001 - 65536, 70002 - 65536] = [4464, 4465, 4466].
    expect(indices, [overflowIndex, overflowIndex + 1, overflowIndex + 2]);
  });

  test(
      'meshBuffersFromMesh doubleSidedWinding: false (the default) is byte-for-byte unchanged - '
      'a regression guard for the face-culling fix below', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final defaulted = meshBuffersFromMesh(mesh);
    final explicit = meshBuffersFromMesh(mesh, doubleSidedWinding: false);

    expect(defaulted.vertexCount, explicit.vertexCount);
    expect(defaulted.vertexData, explicit.vertexData);
    expect(
      Uint32List.sublistView(defaulted.indexData),
      Uint32List.sublistView(explicit.indexData),
    );
  });

  test(
      'meshBuffersFromMesh doubleSidedWinding: true emits a second, reverse-wound, '
      'normal-flipped copy of every triangle - the face-culling bug fix (see '
      'geometryFromMesh\'s doc comment: flutter_scene back-face-culls any translucent '
      'material regardless of Material.doubleSided, so the geometry itself must supply '
      'a back-facing copy)', () {
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [1, 0, 0],
        [0, 1, 0],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
      ],
    );

    final buffers = meshBuffersFromMesh(mesh, doubleSidedWinding: true);

    expect(buffers.vertexCount, 6);

    // First 3 vertices: original positions/normals, unchanged.
    final firstCopyNormalZ = buffers.vertexData[5];
    expect(firstCopyNormalZ, 1);

    // Second 3 vertices: same positions, negated normals.
    final secondCopyPosition = buffers.vertexData.sublist(36, 39);
    expect(secondCopyPosition, [0, 0, 0]); // same position as vertex 0
    final secondCopyNormalZ = buffers.vertexData[41];
    expect(secondCopyNormalZ, -1);

    final indices = Uint32List.sublistView(buffers.indexData);
    expect(indices.length, 6);
    // Front-facing triangle, unchanged.
    expect(indices.sublist(0, 3), [0, 1, 2]);
    // Back-facing triangle: reversed winding, offset into the second vertex copy.
    expect(indices.sublist(3, 6), [3, 5, 4]);
  });

  test('boundsOfMesh returns the bounding box centre, not the vertex average', () {
    // Mirrors the real placeholder mesh's actual bounds - a
    // BRepPrimAPI_MakeBox(10, 10, 10) spans (0,0,0) to (10,10,10), so its
    // genuine bounding-box centre is (5, 5, 5) - lopsided vertex placement
    // (here, three vertices share z=0 and only one sits at z=10) must not
    // pull the centre away from the box's true geometric middle the way a
    // plain vertex-position average would (that would land at z=2.5).
    final mesh = MeshDto(
      vertices: [
        [0, 0, 0],
        [10, 0, 0],
        [0, 10, 0],
        [10, 10, 10],
      ],
      normals: [
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
        [0, 0, 1],
      ],
      triangleIndices: [
        [0, 1, 2],
        [2, 1, 3],
      ],
    );

    final bounds = boundsOfMesh(mesh)!;

    expect(bounds.center.x, closeTo(5, 1e-9));
    expect(bounds.center.y, closeTo(5, 1e-9));
    expect(bounds.center.z, closeTo(5, 1e-9));
    // Bounding box is 10x10x10 - its space diagonal is 10*sqrt(3), so the
    // bounding-sphere radius (half that diagonal) is 5*sqrt(3).
    expect(bounds.boundingSphereRadius, closeTo(5 * 1.7320508, 1e-4));
  });

  test('boundsOfMesh returns null for an empty mesh', () {
    final mesh = MeshDto(vertices: [], normals: [], triangleIndices: []);

    expect(boundsOfMesh(mesh), isNull);
  });

  test('edgeSegmentsFromMesh groups the flat edges array into 6-float segment pairs', () {
    final mesh = MeshDto(
      vertices: [],
      normals: [],
      triangleIndices: [],
      edges: [0, 0, 0, 10, 0, 0, 10, 0, 0, 10, 10, 0],
    );

    final segments = edgeSegmentsFromMesh(mesh);

    expect(segments, hasLength(2));
    expect(segments[0].$1, vm.Vector3(0, 0, 0));
    expect(segments[0].$2, vm.Vector3(10, 0, 0));
    expect(segments[1].$1, vm.Vector3(10, 0, 0));
    expect(segments[1].$2, vm.Vector3(10, 10, 0));
  });

  test('edgeSegmentsFromMesh returns no segments for an empty edges array', () {
    final mesh = MeshDto(vertices: [], normals: [], triangleIndices: [], edges: []);

    expect(edgeSegmentsFromMesh(mesh), isEmpty);
  });

  test('biasSegmentsTowardCamera pushes each point towards the camera by amount', () {
    final segments = [(vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0))];

    final biased = biasSegmentsTowardCamera(segments, vm.Vector3(-5, 0, 0), 1.0);

    // Camera is at x=-5. Both points move 1 unit along -x, towards it.
    expect(biased[0].$1, vm.Vector3(-1, 0, 0));
    expect(biased[0].$2, vm.Vector3(9, 0, 0));
  });

  test('biasSegmentsTowardCamera leaves a point exactly at the camera unchanged', () {
    final segments = [(vm.Vector3(5, 5, 5), vm.Vector3(10, 0, 0))];

    final biased = biasSegmentsTowardCamera(segments, vm.Vector3(5, 5, 5), 1.0);

    expect(biased[0].$1, vm.Vector3(5, 5, 5));
  });

  test(
      'biasTrianglesAlongNormal pushes every vertex along the triangle\'s own outward normal by amount '
      '(bug fix, on-device feedback: selecting a non-visible face - e.g. the far side of a cube via '
      '"Select Other" - highlighted the wrong, inward side; the old biasTrianglesTowardCamera pushed '
      'towards the camera instead, which points *through* the solid for a far/hidden face)', () {
    final triangles = [(vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0), vm.Vector3(0, 10, 0))];

    final biased = biasTrianglesAlongNormal(triangles, 1.0);

    // (b-a).cross(c-a) = (10,0,0).cross(0,10,0) = (0,0,100), normalized (0,0,1) -
    // every vertex pushed 1 unit along +Z, regardless of where the camera is.
    expect(biased[0].$1, vm.Vector3(0, 0, 1));
    expect(biased[0].$2, vm.Vector3(10, 0, 1));
    expect(biased[0].$3, vm.Vector3(0, 10, 1));
  });

  test('biasTrianglesAlongNormal leaves a degenerate (zero-area/collinear) triangle unchanged', () {
    final triangles = [(vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(2, 0, 0))];

    final biased = biasTrianglesAlongNormal(triangles, 1.0);

    expect(biased[0].$1, vm.Vector3(0, 0, 0));
    expect(biased[0].$2, vm.Vector3(1, 0, 0));
    expect(biased[0].$3, vm.Vector3(2, 0, 0));
  });

  test('biasTrianglesAlongNormal pushes a far/hidden-face triangle away from a camera on the near side '
      'the same as a near-face triangle - the direction only depends on the triangle\'s own winding, '
      'never on where the camera is', () {
    // Two triangles with opposite winding (front vs. back face of a thin
    // slab) both push along their own outward normal - one +Z, one -Z -
    // regardless of a shared camera position, unlike the old camera-relative
    // bias which pushed both towards the same camera direction.
    final frontFace = [(vm.Vector3(0, 0, 0), vm.Vector3(10, 0, 0), vm.Vector3(0, 10, 0))];
    final backFace = [(vm.Vector3(0, 0, 0), vm.Vector3(0, 10, 0), vm.Vector3(10, 0, 0))];

    final biasedFront = biasTrianglesAlongNormal(frontFace, 1.0);
    final biasedBack = biasTrianglesAlongNormal(backFace, 1.0);

    expect(biasedFront[0].$1.z, closeTo(1.0, 1e-9));
    expect(biasedBack[0].$1.z, closeTo(-1.0, 1e-9));
  });

  group('vertexMarkerSegments', () {
    test('turns each position into a near-zero-length segment starting at that position', () {
      final segments = vertexMarkerSegments([vm.Vector3(1, 2, 3), vm.Vector3(4, 5, 6)]);

      expect(segments, hasLength(2));
      expect(segments[0].$1, vm.Vector3(1, 2, 3));
      expect((segments[0].$2 - segments[0].$1).length, lessThan(1e-3));
      expect(segments[1].$1, vm.Vector3(4, 5, 6));
      expect((segments[1].$2 - segments[1].$1).length, lessThan(1e-3));
    });

    test('returns no segments for an empty position list', () {
      expect(vertexMarkerSegments([]), isEmpty);
    });
  });

  group('triangleHighlightBuffers', () {
    test('emits front + back face: 6 vertices per input triangle', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
      ]);

      // One input triangle → 2 output triangles (front + back) → 6 vertices.
      expect(buffers.vertexCount, 6);
      // Front-face vertex 0 is unchanged: position (0,0,0), normal +Z.
      final vertex0 = buffers.vertexData.sublist(0, 12);
      expect(vertex0, [
        0, 0, 0, // position
        0, 0, 1, // normal (cross of the two edges, +Z for this winding)
        0, 0, // uv
        1, 1, 1, 1, // color
      ]);
    });

    test('writes a flat 32-bit index buffer of 0..vertexCount-1', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
        (vm.Vector3(0, 0, 0), vm.Vector3(0, 1, 0), vm.Vector3(0, 0, 1)),
      ]);

      // 2 input triangles → 4 output triangles → 12 vertices → 12 indices.
      final indices = Uint32List.sublistView(buffers.indexData);
      expect(indices, [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11]);
    });

    test('a degenerate (zero-area) triangle gets the zero normal rather than NaN', () {
      final buffers = triangleHighlightBuffers([
        (vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 0)),
      ]);

      expect(buffers.vertexData.sublist(3, 6), [0, 0, 0]);
    });
  });

  group('highContrastColorFrom (on-device feedback: selected face colour too similar to body colour)', () {
    final palette = [
      vm.Vector4(1, 0, 0, 1), // red
      vm.Vector4(0, 1, 0, 1), // green
      vm.Vector4(0, 0, 1, 1), // blue
    ];

    test('picks the palette entry furthest from the reference color', () {
      // Closest to blue and green; red is furthest away.
      final reference = vm.Vector4(0.1, 0.4, 0.5, 1);
      expect(highContrastColorFrom(palette, reference), vm.Vector4(1, 0, 0, 1));
    });

    test('a reference color near one palette entry avoids it in favor of a further one', () {
      final reference = vm.Vector4(0.95, 0.05, 0.05, 1); // near-red
      final result = highContrastColorFrom(palette, reference);
      expect(result, isNot(vm.Vector4(1, 0, 0, 1)));
    });

    test('a single-entry palette always returns that entry', () {
      final onlyOption = [vm.Vector4(0.5, 0.5, 0.5, 1)];
      expect(highContrastColorFrom(onlyOption, vm.Vector4(0.5, 0.5, 0.5, 1)), onlyOption.single);
    });
  });

  group('renderMirrorCorrectedMesh (confirmed rendering-pipeline Z-mirror fix)', () {
    MeshDto sampleMesh() => MeshDto(
          vertices: [
            [1, 2, 3],
            [4, 5, 6],
          ],
          normals: [
            [0, 1, 0],
            [1, 0, 0],
          ],
          triangleIndices: [
            [0, 1, 0],
          ],
          edges: [1, 2, 3, 4, 5, 6],
          topologyVertices: [
            [1, 2, 3],
          ],
        );

    test('negates only the Z component of every position field', () {
      final corrected = renderMirrorCorrectedMesh(sampleMesh());
      expect(corrected.vertices, [
        [1, 2, -3],
        [4, 5, -6],
      ]);
      expect(corrected.normals, [
        [0, 1, 0],
        [1, 0, 0],
      ]);
      expect(corrected.edges, [1, 2, -3, 4, 5, -6]);
      expect(corrected.topologyVertices, [
        [1, 2, -3],
      ]);
      // Untouched: indices/ids don't represent positions.
      expect(corrected.triangleIndices, sampleMesh().triangleIndices);
    });

    test('applying it twice restores the original values', () {
      final mesh = sampleMesh();
      final roundTripped = renderMirrorCorrectedMesh(renderMirrorCorrectedMesh(mesh));
      expect(roundTripped.vertices, mesh.vertices);
      expect(roundTripped.edges, mesh.edges);
    });
  });

  // Assembly support Phase 4 (`docs/assembly-scope.md` §3): matches
  // `backend/tests/test_assembly_model.py`'s own transform-composition
  // coverage as closely as a client-side, single-transform (no chain)
  // function can - identity, pure translation, a known-angle rotation, and
  // the 180-degree edge case that identity-vs-negated-axis both round-trip
  // an axis-angle representation identically.
  group('matrix4FromRigidTransform', () {
    RigidTransformDto identity() => RigidTransformDto(
          translation: [0, 0, 0],
          rotationAxis: [0, 0, 0],
          rotationAngleDegrees: 0,
        );

    test('identity transform leaves a point unchanged', () {
      final matrix = matrix4FromRigidTransform(identity());
      final result = matrix.transformed3(vm.Vector3(1, 2, 3));
      expect(result.x, closeTo(1, 1e-9));
      expect(result.y, closeTo(2, 1e-9));
      expect(result.z, closeTo(3, 1e-9));
    });

    test('pure translation moves a point by exactly the translation vector', () {
      final transform = RigidTransformDto(
        translation: [5, -2, 10],
        rotationAxis: [0, 0, 0],
        rotationAngleDegrees: 0,
      );
      final matrix = matrix4FromRigidTransform(transform);
      final result = matrix.transformed3(vm.Vector3(1, 1, 1));
      expect(result.x, closeTo(6, 1e-9));
      expect(result.y, closeTo(-1, 1e-9));
      expect(result.z, closeTo(11, 1e-9));
    });

    test('a 90-degree rotation about +Z maps +X to +Y, then translates', () {
      final transform = RigidTransformDto(
        translation: [1, 0, 0],
        rotationAxis: [0, 0, 1],
        rotationAngleDegrees: 90,
      );
      final matrix = matrix4FromRigidTransform(transform);
      // Rotate-then-translate (per RigidTransform's own docstring): (1,0,0)
      // rotates to (0,1,0), then the translation is added.
      // `vm.Matrix4`/`vm.Vector3` store components as `Float32List` (single
      // precision) internally, so a trig-derived result (unlike the pure
      // integer sums the translation-only tests above check) can land a few
      // ULPs off an exact value - 1e-6 is the same tolerance the 180-degree
      // edge case just below, and elsewhere in this codebase's own geometry
      // tests, already uses for exactly this reason.
      final result = matrix.transformed3(vm.Vector3(1, 0, 0));
      expect(result.x, closeTo(1, 1e-6));
      expect(result.y, closeTo(1, 1e-6));
      expect(result.z, closeTo(0, 1e-6));
    });

    test('a 180-degree rotation about +X maps +Y to -Y (the axis-angle edge case)', () {
      final transform = RigidTransformDto(
        translation: [0, 0, 0],
        rotationAxis: [1, 0, 0],
        rotationAngleDegrees: 180,
      );
      final matrix = matrix4FromRigidTransform(transform);
      final result = matrix.transformed3(vm.Vector3(0, 1, 0));
      expect(result.x, closeTo(0, 1e-6));
      expect(result.y, closeTo(-1, 1e-6));
      expect(result.z, closeTo(0, 1e-6));
    });

    test('a near-zero-length rotation axis is treated as no rotation, not a degenerate normalize', () {
      final transform = RigidTransformDto(
        translation: [2, 0, 0],
        rotationAxis: [0, 0, 0],
        rotationAngleDegrees: 45, // meaningless with a zero-length axis - must be ignored.
      );
      final matrix = matrix4FromRigidTransform(transform);
      final result = matrix.transformed3(vm.Vector3(0, 0, 0));
      expect(result.x, closeTo(2, 1e-9));
      expect(result.y, closeTo(0, 1e-9));
      expect(result.z, closeTo(0, 1e-9));
    });
  });

  // Assembly support Phase 12 (`docs/assembly-scope.md` §6 `[18]`): the
  // client-side counterpart to `backend/app/document/assembly.py`'s own
  // `compose` unit tests (`test_assembly_transform_apply.py`'s own "hand-
  // verified against known rotations" testing style).
  group('composeRigidTransforms', () {
    RigidTransformDto identity() => RigidTransformDto(
          translation: [0, 0, 0],
          rotationAxis: [0, 0, 0],
          rotationAngleDegrees: 0,
        );

    test('identity parent leaves the child transform unchanged', () {
      final child = RigidTransformDto(
        translation: [1, 2, 3],
        rotationAxis: [0, 0, 1],
        rotationAngleDegrees: 45,
      );
      final composed = composeRigidTransforms(identity(), child);
      expect(composed.translation[0], closeTo(1, 1e-6));
      expect(composed.translation[1], closeTo(2, 1e-6));
      expect(composed.translation[2], closeTo(3, 1e-6));
      expect(composed.rotationAngleDegrees, closeTo(45, 1e-4));
    });

    test('identity child leaves the parent transform unchanged', () {
      final parent = RigidTransformDto(
        translation: [5, -2, 10],
        rotationAxis: [0, 1, 0],
        rotationAngleDegrees: 30,
      );
      final composed = composeRigidTransforms(parent, identity());
      expect(composed.translation[0], closeTo(5, 1e-6));
      expect(composed.translation[1], closeTo(-2, 1e-6));
      expect(composed.translation[2], closeTo(10, 1e-6));
      expect(composed.rotationAngleDegrees, closeTo(30, 1e-4));
    });

    test('two pure translations add', () {
      final parent = RigidTransformDto(translation: [10, 0, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final child = RigidTransformDto(translation: [0, 5, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final composed = composeRigidTransforms(parent, child);
      expect(composed.translation[0], closeTo(10, 1e-6));
      expect(composed.translation[1], closeTo(5, 1e-6));
      expect(composed.translation[2], closeTo(0, 1e-6));
    });

    test('a 90-degree parent rotation about +Z carries the child\'s own translation around with it', () {
      // Mirrors `matrix4FromRigidTransform`'s own "a 90-degree rotation
      // about +Z maps +X to +Y" test one level up: a child sitting at
      // (1, 0, 0) relative to a parent rotated +90 about Z lands at world
      // (0, 1, 0) - the same "rotate the whole existing placement" behavior
      // `assembly.py`'s own `compose` docstring (and this app's backend
      // Circular ComponentPattern expansion) already establishes.
      final parent = RigidTransformDto(translation: [0, 0, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 90);
      final child = RigidTransformDto(translation: [1, 0, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final composed = composeRigidTransforms(parent, child);
      expect(composed.translation[0], closeTo(0, 1e-6));
      expect(composed.translation[1], closeTo(1, 1e-6));
      expect(composed.translation[2], closeTo(0, 1e-6));
    });

    test('rotations compose: a 90-degree parent plus a 90-degree child about the same axis totals 180', () {
      final parent = RigidTransformDto(translation: [0, 0, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 90);
      final child = RigidTransformDto(translation: [0, 0, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 90);
      final composed = composeRigidTransforms(parent, child);
      expect(composed.rotationAngleDegrees, closeTo(180, 1e-4));
    });

    test('a rotated parent still correctly places a translated-and-rotated child', () {
      // parent: translate (10, 0, 0), no rotation. child: translate (0, 5,
      // 0), no rotation. World position: parent's own rotation (identity)
      // applied to the child's translation, plus the parent's own
      // translation -> (10, 5, 0). Cross-checked against the plain-Matrix4
      // path directly (not just against this function's own math) so a bug
      // shared between the production code and a hand-derived expectation
      // can't hide from this test.
      final parent = RigidTransformDto(translation: [10, 0, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 0);
      final child = RigidTransformDto(translation: [0, 5, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 0);
      final composed = composeRigidTransforms(parent, child);
      final expectedMatrix = matrix4FromRigidTransform(parent) * matrix4FromRigidTransform(child);
      final expectedPoint = expectedMatrix.transformed3(vm.Vector3.zero());
      expect(composed.translation[0], closeTo(expectedPoint.x, 1e-6));
      expect(composed.translation[1], closeTo(expectedPoint.y, 1e-6));
      expect(composed.translation[2], closeTo(expectedPoint.z, 1e-6));
    });
  });

  group('localRigidTransformRelativeTo', () {
    test('is the exact inverse of composeRigidTransforms', () {
      final parent = RigidTransformDto(translation: [3, -1, 7], rotationAxis: [0, 1, 0], rotationAngleDegrees: 40);
      final local = RigidTransformDto(translation: [1, 2, 3], rotationAxis: [1, 0, 0], rotationAngleDegrees: 25);
      final world = composeRigidTransforms(parent, local);
      final recovered = localRigidTransformRelativeTo(parent, world);
      expect(recovered.translation[0], closeTo(local.translation[0], 1e-5));
      expect(recovered.translation[1], closeTo(local.translation[1], 1e-5));
      expect(recovered.translation[2], closeTo(local.translation[2], 1e-5));
      expect(recovered.rotationAngleDegrees, closeTo(local.rotationAngleDegrees, 1e-3));
    });

    test('an identity parent leaves world and local identical', () {
      final identity = RigidTransformDto(translation: [0, 0, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final world = RigidTransformDto(translation: [5, 6, 7], rotationAxis: [0, 0, 1], rotationAngleDegrees: 60);
      final local = localRigidTransformRelativeTo(identity, world);
      expect(local.translation[0], closeTo(5, 1e-6));
      expect(local.translation[1], closeTo(6, 1e-6));
      expect(local.translation[2], closeTo(7, 1e-6));
      expect(local.rotationAngleDegrees, closeTo(60, 1e-4));
    });

    test('a pure-translation parent subtracts its own translation back out', () {
      final parent = RigidTransformDto(translation: [10, 0, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final world = RigidTransformDto(translation: [15, 5, 0], rotationAxis: [0, 0, 0], rotationAngleDegrees: 0);
      final local = localRigidTransformRelativeTo(parent, world);
      expect(local.translation[0], closeTo(5, 1e-6));
      expect(local.translation[1], closeTo(5, 1e-6));
      expect(local.translation[2], closeTo(0, 1e-6));
    });
  });

  // Assembly support Phase 4: the opacity half of "opacity/selectability
  // split for non-primary Parts" - pure and directly testable, independent
  // of [buildAssemblyInstanceNode]'s own GPU-bound Node construction.
  group('assemblyInstanceOpacity', () {
    test('every instance is fully opaque while no focus is active, regardless of isFocusedInstance', () {
      expect(assemblyInstanceOpacity(focusActive: false, isFocusedInstance: false), 1.0);
      expect(assemblyInstanceOpacity(focusActive: false, isFocusedInstance: true), 1.0);
    });

    test('the focused instance stays fully opaque once a focus is active', () {
      expect(assemblyInstanceOpacity(focusActive: true, isFocusedInstance: true), 1.0);
    });

    test('every other instance fades to kNonPrimaryAssemblyOpacity once a focus is active', () {
      expect(assemblyInstanceOpacity(focusActive: true, isFocusedInstance: false), kNonPrimaryAssemblyOpacity);
      expect(kNonPrimaryAssemblyOpacity, lessThan(1.0));
    });
  });
}
