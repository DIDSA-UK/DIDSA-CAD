import 'dart:ui';

import 'package:flutter_scene/scene.dart' show PerspectiveCamera;
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/box_select.dart';
import 'package:didsa_cad_client/viewport3d/orthographic_camera.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

/// Desktop input D7 (`docs/desktop-input-scope.md`): what a 3D box picks,
/// against known cameras.

const _size = Size(800, 600);

/// A cube of side 2 centred on the origin: faces 0..5, edges 0..11,
/// topology vertices 0..7.
MeshDto _cube() {
  final corners = [
    for (final z in [-1.0, 1.0])
      for (final y in [-1.0, 1.0])
        for (final x in [-1.0, 1.0]) [x, y, z],
  ];
  // Corner index = x + 2*y + 4*z (bits), each face lists its four corners.
  const faces = [
    [0, 1, 3, 2], // z = -1
    [4, 5, 7, 6], // z = +1
    [0, 1, 5, 4], // y = -1
    [2, 3, 7, 6], // y = +1
    [0, 2, 6, 4], // x = -1
    [1, 3, 7, 5], // x = +1
  ];
  final triangles = <List<int>>[];
  final faceIds = <int>[];
  for (var f = 0; f < faces.length; f++) {
    final q = faces[f];
    triangles..add([q[0], q[1], q[2]])..add([q[0], q[2], q[3]]);
    faceIds..add(f)..add(f);
  }
  final edgePairs = <List<int>>[];
  for (var a = 0; a < 8; a++) {
    for (var bit = 1; bit < 8; bit <<= 1) {
      if (a & bit == 0) edgePairs.add([a, a | bit]);
    }
  }
  final edges = <double>[];
  for (final e in edgePairs) {
    edges..addAll(corners[e[0]])..addAll(corners[e[1]]);
  }
  return MeshDto(
    vertices: corners,
    normals: [for (final _ in corners) [0.0, 0.0, 1.0]],
    triangleIndices: triangles,
    edges: edges,
    faceIds: faceIds,
    edgeIds: List.generate(edgePairs.length, (i) => i),
    topologyVertices: corners,
    topologyVertexIds: List.generate(8, (i) => i),
  );
}

PerspectiveCamera _front() => PerspectiveCamera(position: vm.Vector3(0, 0, 10), target: vm.Vector3.zero(), up: vm.Vector3(0, 1, 0));

BoxSelectShape _shape({vm.Vector3? at, String id = 'b', String occurrence = ''}) => BoxSelectShape(
      bodyId: id,
      occurrenceId: occurrence,
      mesh: _cube(),
      transform: at == null ? null : vm.Matrix4.translation(at),
    );

List<SelectionEntityRef> _box(
  List<BoxSelectShape> shapes,
  Rect rect, {
  bool crossing = false,
  BoxSelectTarget target = BoxSelectTarget.edges,
  dynamic camera,
  bool occlude = true,
}) =>
    boxSelect(
      camera: camera ?? _front(),
      viewportSize: _size,
      shapes: shapes,
      rect: rect,
      crossing: crossing,
      target: target,
      occlude: occlude,
    );

const _everything = Rect.fromLTWH(0, 0, 800, 600);

void main() {
  group('edges (the default target)', () {
    test('a window around the whole cube takes only its visible edges, not the four behind', () {
      final edges = _box([_shape()], _everything);
      // From the front a cube shows its front square's 4 edges and, in
      // perspective, the four edges running back; the back square is hidden
      // behind the front face, so the ones that are visible are the 8 near ones.
      expect(edges.map((e) => e.id).toSet().length, edges.length);
      expect(edges.length, 8);
    });

    test('a window with no occlusion takes all twelve', () {
      expect(_box([_shape()], _everything, occlude: false), hasLength(12));
    });

    test('a window that cuts the cube takes only the edges wholly inside; a crossing box also takes the ones it touches', () {
      const left = Rect.fromLTWH(0, 0, 400, 600);
      final window = _box([_shape()], left);
      final touching = _box([_shape()], left, crossing: true);
      expect(window.length, lessThan(touching.length));
      expect(touching, containsAll(window));
    });

    test('a box beside the cube picks nothing either way', () {
      const away = Rect.fromLTWH(0, 0, 50, 50);
      expect(_box([_shape()], away), isEmpty);
      expect(_box([_shape()], away, crossing: true), isEmpty);
    });

    test('a hidden back edge is not picked even when it is inside the box', () {
      // A box over the cube's middle: only the back square's edges and the
      // front square's edges can be inside it; the back ones are behind the face.
      // The back square is about 66 px from the centre, the front one 80: a
      // 150 px box holds the back square's edges but none of the front's.
      final centre = Rect.fromCenter(center: const Offset(400, 300), width: 150, height: 150);
      expect(_box([_shape()], centre, crossing: true), isEmpty);
      expect(_box([_shape()], centre, crossing: true, occlude: false), isNotEmpty);
    });

    test('a body behind another is not picked through it', () {
      final shapes = [_shape(id: 'near'), _shape(id: 'far', at: vm.Vector3(0, 0, -6))];
      final picked = _box(shapes, _everything);
      expect(picked.where((e) => e.bodyId == 'far'), isEmpty);
      expect(picked.where((e) => e.bodyId == 'near'), isNotEmpty);
    });

    test('a body beside another is picked with it', () {
      final shapes = [_shape(id: 'a', at: vm.Vector3(-1.2, 0, 0)), _shape(id: 'b', at: vm.Vector3(1.2, 0, 0))];
      final picked = _box(shapes, _everything);
      expect(picked.map((e) => e.bodyId).toSet(), {'a', 'b'});
    });

    test('works with an orthographic camera too', () {
      final camera = OrthographicCamera(
        position: vm.Vector3(0, 0, 10),
        target: vm.Vector3.zero(),
        up: vm.Vector3(0, 1, 0),
        halfHeight: 3,
      );
      // Looking straight on, the front and back squares coincide on screen:
      // four visible edges (the front square) and the four depth edges are points.
      final picked = _box([_shape()], _everything, camera: camera);
      expect(picked.length, greaterThanOrEqualTo(4));
      expect(_box([_shape()], _everything, camera: camera, occlude: false), hasLength(12));
    });

    test('a part moved by a transform is where the box finds it', () {
      // -X is to the right in this camera.
      final shifted = _shape(at: vm.Vector3(-3, 0, 0));
      const leftHalf = Rect.fromLTWH(0, 0, 400, 600);
      expect(_box([shifted], leftHalf, crossing: true), isEmpty);
      const rightHalf = Rect.fromLTWH(400, 0, 400, 600);
      expect(_box([shifted], rightHalf), isNotEmpty);
    });

    test('edges carry the occurrence they belong to', () {
      final picked = _box([_shape(occurrence: 'occ1')], _everything);
      expect(picked.every((e) => e.occurrenceId == 'occ1'), isTrue);
    });
  });

  group('other targets', () {
    test('faces: from the front only the front face is seen', () {
      final faces = _box([_shape()], _everything, crossing: true, target: BoxSelectTarget.faces);
      expect(faces.map((e) => e.id).toSet(), contains(1));
      expect(faces.length, lessThan(6));
    });

    test('faces: a window must hold the whole face', () {
      final centre = Rect.fromCenter(center: const Offset(400, 300), width: 60, height: 60);
      expect(_box([_shape()], centre, target: BoxSelectTarget.faces), isEmpty);
      expect(_box([_shape()], centre, crossing: true, target: BoxSelectTarget.faces), isNotEmpty);
    });

    test('vertices: visible corners inside the box', () {
      final vertices = _box([_shape()], _everything, target: BoxSelectTarget.vertices);
      expect(vertices.length, 4);
    });

    test('bodies: a window takes a whole body, a crossing box any visible part', () {
      const left = Rect.fromLTWH(0, 0, 400, 600);
      expect(_box([_shape()], left, target: BoxSelectTarget.bodies), isEmpty);
      expect(_box([_shape()], left, crossing: true, target: BoxSelectTarget.bodies), hasLength(1));
      expect(_box([_shape()], _everything, target: BoxSelectTarget.bodies).single.kind, SelectionEntityKind.body);
    });

    test('components: whole placed instances, the Part\'s own Bodies are not components', () {
      final shapes = [
        _shape(id: 'own'),
        _shape(id: 'x', occurrence: 'occ-a', at: vm.Vector3(-1.2, 0, 0)),
        _shape(id: 'y', occurrence: 'occ-b', at: vm.Vector3(1.2, 0, 0)),
      ];
      final picked = _box(shapes, _everything, target: BoxSelectTarget.components);
      expect(picked.every((e) => e.kind == SelectionEntityKind.component), isTrue);
      expect(picked.map((e) => e.occurrenceId).toSet(), {'occ-a', 'occ-b'});
    });

    test('components: one hidden entirely behind another is not picked', () {
      final shapes = [
        _shape(id: 'x', occurrence: 'near'),
        _shape(id: 'y', occurrence: 'far', at: vm.Vector3(0, 0, -6)),
      ];
      final picked = _box(shapes, _everything, target: BoxSelectTarget.components);
      expect(picked.map((e) => e.occurrenceId), ['near']);
    });
  });

  test('an empty or off-screen box picks nothing', () {
    expect(_box([_shape()], Rect.zero), isEmpty);
    expect(_box([_shape()], const Rect.fromLTWH(900, 700, 50, 50), crossing: true), isEmpty);
  });
}
