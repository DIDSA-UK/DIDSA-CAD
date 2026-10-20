// The flat app's look of an appearance (`lib/appearance/appearance_look.dart`): material values over the viewport's defaults,
// glow as the backend's glb material makes it, and a body mesh split into one piece per look.
import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/appearance/appearance_look.dart';

MeshDto _mesh() => MeshDto(
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
        [1, 3, 2],
        [0, 2, 3],
      ],
      faceIds: [0, 1, 1],
    );

void main() {
  group('LookParams', () {
    test('unset fields take the defaults', () {
      final p = LookParams.of({}, defaultColour: vm.Vector3(0.1, 0.2, 0.3), defaultRoughness: 0.5, defaultMetallic: 0.2);
      expect(p.colour, vm.Vector3(0.1, 0.2, 0.3));
      expect([p.opacity, p.roughness, p.metallic], [1.0, 0.5, 0.2]);
      expect(p.emissive, vm.Vector3.zero());
    });

    test('set fields win, the colour is the hex as picked', () {
      final p = LookParams.of({'colour': '#FF8000', 'opacity': 0.4, 'metallic': 1.0, 'roughness': 0.1});
      expect(p.colour.x, closeTo(1.0, 1e-6)); // (vector_math is float32)
      expect(p.colour.y, closeTo(128 / 255, 1e-6));
      expect(p.opacity, 0.4);
      expect(p.metallic, 1.0);
      expect(p.roughness, 0.1);
    });

    test('glow: emission scaled by its strength; only a strength glows in the base colour; strength 0 is off', () {
      expect(LookParams.of({'colour': '#FF0000', 'emission': '#00FF00', 'emission_strength': 2.0}).emissive, vm.Vector3(0, 2, 0));
      expect(LookParams.of({'colour': '#FF0000', 'emission_strength': 3.0}).emissive, vm.Vector3(3, 0, 0));
      expect(LookParams.of({'emission': '#FFFFFF'}).emissive, vm.Vector3(1, 1, 1));
      expect(LookParams.of({'colour': '#FF0000', 'emission_strength': 0.0}).emissive, vm.Vector3.zero());
    });
  });

  group('splitMeshByLook', () {
    test('no face looks: the mesh as it is', () {
      final mesh = _mesh();
      final pieces = splitMeshByLook(mesh, 'b', {'colour': '#111111'}, null);
      expect(pieces, hasLength(1));
      expect(identical(pieces.single.$1, mesh), isTrue);
      expect(pieces.single.$2, {'colour': '#111111'});
    });

    test('one piece per distinct look; an unlisted face takes the whole look; vertices shared', () {
      final mesh = _mesh();
      final pieces = splitMeshByLook(mesh, 'b', {'colour': '#111111'}, {
        'b|1': {'colour': '#FF0000'},
        'other|0': {'colour': '#00FF00'},
      });
      expect(pieces, hasLength(2));
      final red = pieces.firstWhere((p) => p.$2['colour'] == '#FF0000').$1;
      final plain = pieces.firstWhere((p) => p.$2['colour'] == '#111111').$1;
      expect(red.triangleIndices, [
        [1, 3, 2],
        [0, 2, 3],
      ]);
      expect(red.faceIds, [1, 1]);
      expect(plain.triangleIndices, [
        [0, 1, 2],
      ]);
      expect(identical(red.vertices, mesh.vertices), isTrue);
    });

    test('faces that all look the same as each other stay one piece', () {
      final pieces = splitMeshByLook(_mesh(), 'b', {}, {
        'b|0': {'colour': '#FF0000'},
        'b|1': {'colour': '#FF0000'},
      });
      expect(pieces, hasLength(1));
      expect(pieces.single.$2, {'colour': '#FF0000'});
    });
  });

  test('InstanceLook.isEmpty', () {
    expect(const InstanceLook().isEmpty, isTrue);
    expect(const InstanceLook(whole: {'opacity': 0.5}).isEmpty, isFalse);
    expect(const InstanceLook(faces: {'b|0': {}}).isEmpty, isTrue);
  });
}
