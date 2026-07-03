import 'dart:ui' show Size;

import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/selection_filter.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

void main() {
  // Every ray below travels straight down +Z from the origin - the
  // worked-out pixel-distance numbers in each test's comments assume this
  // exact ray plus a 800x600 viewport at the default 45-degree vertical
  // FOV (kCameraVerticalFovRadians): at depth z, one screen pixel covers
  // `2 * z * tan(22.5deg) / 600` world units.
  final straightDownZ = vm.Ray.originDirection(vm.Vector3(0, 0, 0), vm.Vector3(0, 0, 1));
  const viewportSize = Size(800, 600);

  group('hitTestVertices', () {
    test('a vertex within the pixel radius at its depth is hit', () {
      // At depth 10, world-units-per-pixel ~= 0.0138, so 9px ~= 0.1243
      // world units - this vertex sits 0.05 off the ray, well inside.
      final hit = hitTestVertices(
        straightDownZ,
        viewportSize,
        [vm.Vector3(0.05, 0, 10)],
        [3],
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3));
    });

    test('a vertex outside the pixel radius at its depth is not hit', () {
      // 0.2 world units off the ray at depth 10 is ~14.5px - past the
      // default 9px radius.
      final hit = hitTestVertices(
        straightDownZ,
        viewportSize,
        [vm.Vector3(0.2, 0, 10)],
        [3],
      );
      expect(hit, isNull);
    });

    test('a vertex behind the ray origin is never hit', () {
      final hit = hitTestVertices(
        straightDownZ,
        viewportSize,
        [vm.Vector3(0, 0, -5)],
        [3],
      );
      expect(hit, isNull);
    });

    test('the nearer of two in-radius vertices wins', () {
      final hit = hitTestVertices(
        straightDownZ,
        viewportSize,
        [vm.Vector3(0.05, 0, 10), vm.Vector3(0.01, 0, 10)],
        [3, 9],
      );
      expect(hit?.entity.id, 9);
    });
  });

  group('hitTestEdges', () {
    test('a segment whose closest point to the ray is within radius is hit', () {
      final hit = hitTestEdges(
        straightDownZ,
        viewportSize,
        [(vm.Vector3(0.05, -1, 10), vm.Vector3(0.05, 1, 10))],
        [5],
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.edge, id: 5));
    });

    test('a segment whose closest point is outside radius is not hit', () {
      final hit = hitTestEdges(
        straightDownZ,
        viewportSize,
        [(vm.Vector3(0.5, -1, 10), vm.Vector3(0.5, 1, 10))],
        [5],
      );
      expect(hit, isNull);
    });

    test('the segment endpoint is respected: the closest point cannot fall outside it', () {
      // The infinite line through this segment passes within 0.05 of the
      // ray at y=0, but the segment itself only spans y in [1, 2] - its
      // nearest actual point is the y=1 endpoint, far from the ray.
      final hit = hitTestEdges(
        straightDownZ,
        viewportSize,
        [(vm.Vector3(0.05, 1, 10), vm.Vector3(0.05, 2, 10))],
        [5],
      );
      expect(hit, isNull);
    });

    test('a segment entirely behind the ray origin is never hit', () {
      final hit = hitTestEdges(
        straightDownZ,
        viewportSize,
        [(vm.Vector3(0, -1, -5), vm.Vector3(0, 1, -5))],
        [5],
      );
      expect(hit, isNull);
    });
  });

  group('hitTestFaces', () {
    final triangle = (vm.Vector3(-1, -1, 10), vm.Vector3(1, -1, 10), vm.Vector3(0, 1, 10));

    test('a ray through the triangle is hit, with no radius check', () {
      final hit = hitTestFaces(straightDownZ, [triangle], [4]);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.face, id: 4));
    });

    test('a ray that misses the triangle entirely returns null', () {
      final missRay = vm.Ray.originDirection(vm.Vector3(5, 5, 0), vm.Vector3(0, 0, 1));
      final hit = hitTestFaces(missRay, [triangle], [4]);
      expect(hit, isNull);
    });

    test('the nearer of two overlapping triangles wins', () {
      final near = (vm.Vector3(-1, -1, 5), vm.Vector3(1, -1, 5), vm.Vector3(0, 1, 5));
      final far = (vm.Vector3(-1, -1, 10), vm.Vector3(1, -1, 10), vm.Vector3(0, 1, 10));
      final hit = hitTestFaces(straightDownZ, [far, near], [1, 2]);
      expect(hit?.entity.id, 2);
    });
  });

  group('topologyVerticesFromMesh / trianglesFromMesh', () {
    test('parses topologyVertices into Vector3s in order', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [1, 2, 3],
          [4, 5, 6],
        ],
      );
      final parsed = topologyVerticesFromMesh(mesh);
      expect(parsed, [vm.Vector3(1, 2, 3), vm.Vector3(4, 5, 6)]);
    });

    test('resolves triangleIndices into actual corner positions', () {
      final mesh = MeshDto(
        vertices: const [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
        ],
        normals: const [],
        triangleIndices: const [
          [0, 1, 2],
        ],
      );
      final parsed = trianglesFromMesh(mesh);
      expect(parsed, [(vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0))]);
    });
  });

  group('hitTestMeshEntities', () {
    test('a vertex wins over an in-radius edge when it is strictly nearer', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [0.02, 0, 10],
        ],
        topologyVertexIds: const [3],
        edges: const [0.05, -1, 10, 0.05, 1, 10],
        edgeIds: const [5],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3));
    });

    test('an exact vertex/edge tie resolves to the vertex', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [0.05, 0, 10],
        ],
        topologyVertexIds: const [3],
        edges: const [0.05, -1, 10, 0.05, 1, 10],
        edgeIds: const [5],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3));
    });

    test('a vertex within its own radius wins even when a different edge is strictly nearer', () {
      // Regression test for a real bug: a vertex sits at the shared
      // endpoint of one or more edges, so comparing raw pixel distance (the
      // old logic) meant an edge's closest point - free to slide along the
      // segment toward wherever the cursor actually is - would beat the
      // fixed vertex point for almost any cursor position off its exact
      // projected pixel. That defeated the whole purpose of vertices having
      // their own in-radius check at all: in practice a vertex could
      // (almost) never win once any edge was anywhere nearby, no matter how
      // generous its own radius was. Here the vertex (~10.8px off-ray) is
      // within kVertexSelectionHitRadiusPixels, while an unrelated edge
      // (~1.4px off-ray) is far closer in raw distance - the vertex must
      // still win because it's in-radius at all, not because it's nearer
      // than the edge (bug-fix round: kVertexSelectionHitRadiusPixels and
      // kSelectionHitRadiusPixels are now equal - see their doc comments -
      // but this priority-over-raw-distance behaviour is independent of
      // that and still needs covering).
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [0.15, 0, 10],
        ],
        topologyVertexIds: const [3],
        edges: const [0.02, -1, 10, 0.02, 1, 10],
        edgeIds: const [5],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3));
    });

    test('a vertex with no competing edge/face nearby is hit on its own radius', () {
      // 12px off-ray at depth 10, well within kVertexSelectionHitRadiusPixels
      // (12.5px as of the bug-fix round - see its doc comment).
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [0.166, 0, 10],
        ],
        topologyVertexIds: const [3],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3));
    });

    test('an in-radius edge wins over a far vertex', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [0.5, 0, 10],
        ],
        topologyVertexIds: const [3],
        edges: const [0.02, -1, 10, 0.02, 1, 10],
        edgeIds: const [5],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.edge, id: 5));
    });

    test('falls back to the nearest intersected face when nothing is within radius', () {
      final mesh = MeshDto(
        vertices: const [
          [-1, -1, 10],
          [1, -1, 10],
          [0, 1, 10],
        ],
        normals: const [],
        triangleIndices: const [
          [0, 1, 2],
        ],
        faceIds: const [7],
        topologyVertices: const [
          [5, 5, 10],
        ],
        topologyVertexIds: const [3],
        edges: const [5, 4, 10, 5, 6, 10],
        edgeIds: const [5],
      );
      final hit = hitTestMeshEntities(ray: straightDownZ, viewportSize: viewportSize, mesh: mesh);
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.face, id: 7));
    });

    test('returns null when nothing in the mesh is near the ray or intersected by it', () {
      final mesh = MeshDto(
        vertices: const [
          [-1, -1, 10],
          [1, -1, 10],
          [0, 1, 10],
        ],
        normals: const [],
        triangleIndices: const [
          [0, 1, 2],
        ],
        faceIds: const [7],
      );
      final missRay = vm.Ray.originDirection(vm.Vector3(50, 50, 0), vm.Vector3(0, 0, 1));
      final hit = hitTestMeshEntities(ray: missRay, viewportSize: viewportSize, mesh: mesh);
      expect(hit, isNull);
    });

    group('Prompt A2: filter gating', () {
      // A mesh with a topology vertex, an edge, and a face all reachable
      // from the same ray - deliberately overlapping (as the pure
      // vertex/edge priority tests above already exercise) so turning a
      // filter off is provably the only thing that changes the result
      // (the underlying geometry never does).
      MeshDto overlappingMesh() => MeshDto(
            vertices: const [
              [-1, -1, 10],
              [1, -1, 10],
              [0, 1, 10],
            ],
            normals: const [],
            triangleIndices: const [
              [0, 1, 2],
            ],
            faceIds: const [7],
            topologyVertices: const [
              [0.02, 0, 10],
            ],
            topologyVertexIds: const [3],
            edges: const [0.05, -1, 10, 0.05, 1, 10],
            edgeIds: const [5],
          );

      test('default filter behaves exactly as before (vertex wins)', () {
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: overlappingMesh(),
        );
        expect(hit?.entity.kind, SelectionEntityKind.vertex);
      });

      test('vertex filter off: falls through to the edge even though the vertex is nearer', () {
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: overlappingMesh(),
          filter: const SelectionFilterState(vertex: false, edge: true, face: true, body: false),
        );
        expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.edge, id: 5));
      });

      test('vertex and edge filters off: falls through to the face', () {
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: overlappingMesh(),
          filter: const SelectionFilterState(vertex: false, edge: false, face: true, body: false),
        );
        expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.face, id: 7));
      });

      test('every filter off: nothing is ever hit, even where geometry exists', () {
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: overlappingMesh(),
          filter: const SelectionFilterState(vertex: false, edge: false, face: false, body: false),
        );
        expect(hit, isNull);
      });

      test('edge filter off alone does not affect vertex priority', () {
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: overlappingMesh(),
          filter: const SelectionFilterState(vertex: true, edge: false, face: true, body: false),
        );
        expect(hit?.entity.kind, SelectionEntityKind.vertex);
      });

      test('face filter off: a would-be face fallback instead returns null', () {
        final mesh = MeshDto(
          vertices: const [
            [-1, -1, 10],
            [1, -1, 10],
            [0, 1, 10],
          ],
          normals: const [],
          triangleIndices: const [
            [0, 1, 2],
          ],
          faceIds: const [7],
        );
        final hit = hitTestMeshEntities(
          ray: straightDownZ,
          viewportSize: viewportSize,
          mesh: mesh,
          filter: const SelectionFilterState(vertex: true, edge: true, face: false, body: false),
        );
        expect(hit, isNull);
      });
    });
  });

  group('vertexPositionForId', () {
    test('returns the position of the matching topology vertex', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [1, 2, 3],
          [4, 5, 6],
        ],
        topologyVertexIds: const [10, 20],
      );
      expect(vertexPositionForId(mesh, 20), vm.Vector3(4, 5, 6));
    });

    test('returns null when the id is not present', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        topologyVertices: const [
          [1, 2, 3],
        ],
        topologyVertexIds: const [10],
      );
      expect(vertexPositionForId(mesh, 99), isNull);
    });
  });

  group('edgeSegmentsForId', () {
    test('returns every segment sharing the given edge id, in order', () {
      // Simulates one curved edge sampled into two segments sharing id 5,
      // plus an unrelated straight edge with id 6.
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        edges: const [
          0, 0, 0, 1, 0, 0, // segment 0, id 5
          1, 0, 0, 2, 0, 0, // segment 1, id 5
          0, 1, 0, 0, 2, 0, // segment 2, id 6
        ],
        edgeIds: const [5, 5, 6],
      );
      final segments = edgeSegmentsForId(mesh, 5);
      expect(segments, [
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0)),
        (vm.Vector3(1, 0, 0), vm.Vector3(2, 0, 0)),
      ]);
    });

    test('returns an empty list when the id is not present', () {
      final mesh = MeshDto(
        vertices: const [],
        normals: const [],
        triangleIndices: const [],
        edges: const [0, 0, 0, 1, 0, 0],
        edgeIds: const [5],
      );
      expect(edgeSegmentsForId(mesh, 99), isEmpty);
    });
  });

  group('faceTrianglesForId', () {
    test('returns every triangle sharing the given face id, in order', () {
      // Simulates one OCCT face tessellated into two triangles sharing id 2,
      // plus an unrelated triangle with id 3.
      final mesh = MeshDto(
        vertices: const [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
          [1, 1, 0],
          [5, 5, 5],
          [6, 5, 5],
          [5, 6, 5],
        ],
        normals: const [],
        triangleIndices: const [
          [0, 1, 2],
          [1, 3, 2],
          [4, 5, 6],
        ],
        faceIds: const [2, 2, 3],
      );
      final triangles = faceTrianglesForId(mesh, 2);
      expect(triangles, [
        (vm.Vector3(0, 0, 0), vm.Vector3(1, 0, 0), vm.Vector3(0, 1, 0)),
        (vm.Vector3(1, 0, 0), vm.Vector3(1, 1, 0), vm.Vector3(0, 1, 0)),
      ]);
    });

    test('returns an empty list when the id is not present', () {
      final mesh = MeshDto(
        vertices: const [
          [0, 0, 0],
          [1, 0, 0],
          [0, 1, 0],
        ],
        normals: const [],
        triangleIndices: const [
          [0, 1, 2],
        ],
        faceIds: const [2],
      );
      expect(faceTrianglesForId(mesh, 99), isEmpty);
    });
  });

  group('Prompt A3: hitTestBodies', () {
    // Two independent boxes at different depths along the same ray, each
    // with a topology vertex, an edge, and a face - lets every priority
    // rule be exercised across bodies, not just within one.
    //
    // `nearBody`'s vertex/edge offset (0.01) is deliberately much smaller
    // than `farBody`'s (0.06) so `nearBody` unambiguously wins the
    // *pixel*-distance comparison `hitTestVertices`/`hitTestEdges` actually
    // use - depth alone does NOT decide this: `_worldUnitsPerPixelAtDepth`
    // scales with depth, so the *same* world-space offset maps to a
    // *larger* pixel distance at `nearBody`'s closer depth (a fixed-size
    // offset looks bigger the closer it is to the camera - the reason two
    // equal offsets would actually have made `farBody` win here, not
    // `nearBody`).
    BodyMeshDto nearBody() => BodyMeshDto(
          bodyId: 'near',
          source: 'computed',
          mesh: MeshDto(
            vertices: const [
              [-1, -1, 5],
              [1, -1, 5],
              [0, 1, 5],
            ],
            normals: const [],
            triangleIndices: const [
              [0, 1, 2],
            ],
            faceIds: const [7],
            topologyVertices: const [
              [0.01, 0, 5],
            ],
            topologyVertexIds: const [3],
            edges: const [0.01, -1, 5, 0.01, 1, 5],
            edgeIds: const [5],
          ),
        );

    BodyMeshDto farBody() => BodyMeshDto(
          bodyId: 'far',
          source: 'computed',
          mesh: MeshDto(
            vertices: const [
              [-1, -1, 10],
              [1, -1, 10],
              [0, 1, 10],
            ],
            normals: const [],
            triangleIndices: const [
              [0, 1, 2],
            ],
            faceIds: const [7],
            topologyVertices: const [
              [0.06, 0, 10],
            ],
            topologyVertexIds: const [3],
            edges: const [0.06, -1, 10, 0.06, 1, 10],
            edgeIds: const [5],
          ),
        );

    test('a vertex hit is tagged with its owning body id', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.vertex, bodyId: 'near', id: 3));
    });

    test('same local id (3) on two different bodies does not collide - order in the list is irrelevant', () {
      // Both bodies' vertex is id 3 - exactly the "ids are only body-local"
      // scenario SelectionEntityRef.bodyId exists to disambiguate. Listing
      // farBody first proves the winner is genuinely decided by the
      // pixel-distance comparison, not by list position.
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [farBody(), nearBody()],
      );
      expect(hit?.entity.bodyId, 'near');
      expect(hit?.entity.id, 3);
    });

    test('an edge hit (vertex filtered off) is tagged with its owning body id', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: false, edge: true, face: true, body: false),
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.edge, bodyId: 'near', id: 5));
    });

    test('a plain face hit (vertex/edge off, body off) is tagged with its owning body id', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: false, edge: false, face: true, body: false),
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.face, bodyId: 'near', id: 7));
    });

    test('body filter on: a face hit resolves to the owning body, not the face', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: false, edge: false, face: false, body: true),
      );
      expect(hit?.entity, const SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'near'));
    });

    test('body filter takes precedence over face filter when both are on', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: false, edge: false, face: true, body: true),
      );
      expect(hit?.entity.kind, SelectionEntityKind.body);
    });

    test('body filter on but nothing intersected returns null', () {
      final missRay = vm.Ray.originDirection(vm.Vector3(50, 50, 0), vm.Vector3(0, 0, 1));
      final hit = hitTestBodies(
        ray: missRay,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: false, edge: false, face: false, body: true),
      );
      expect(hit, isNull);
    });

    test('vertex priority still applies across bodies even with body filter on', () {
      final hit = hitTestBodies(
        ray: straightDownZ,
        viewportSize: viewportSize,
        bodies: [nearBody(), farBody()],
        filter: const SelectionFilterState(vertex: true, edge: true, face: true, body: true),
      );
      // The near body's vertex is in range and wins outright, same
      // vertex-over-everything priority hitTestMeshEntities already has.
      expect(hit?.entity.kind, SelectionEntityKind.vertex);
      expect(hit?.entity.bodyId, 'near');
    });

    test('empty bodies list returns null', () {
      final hit = hitTestBodies(ray: straightDownZ, viewportSize: viewportSize, bodies: const []);
      expect(hit, isNull);
    });
  });
}
