import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/assembly_instance_render.dart';
import 'package:didsa_cad_client/viewport3d/render_mode.dart';

MeshDto _mesh() => MeshDto(
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

RigidTransformDto _at(double x) =>
    RigidTransformDto(translation: [x, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

AssemblyOccurrenceInstanceDto _instance(List<String> path, double x) =>
    AssemblyOccurrenceInstanceDto(occurrencePath: path, partId: 'p', worldTransform: _at(x));

void main() {
  group('isRenderableAssemblyBody', () {
    test('a real computed body is rendered', () {
      expect(isRenderableAssemblyBody(BodyMeshDto(bodyId: 'b', source: 'computed', mesh: _mesh())), isTrue);
      expect(isRenderableAssemblyBody(BodyMeshDto(bodyId: 'b', source: 'coarse', mesh: _mesh())), isTrue);
    });

    test('the "no geometry yet" placeholder box is never rendered in an assembly scene', () {
      expect(isRenderableAssemblyBody(BodyMeshDto(bodyId: 'placeholder', source: 'placeholder', mesh: _mesh())), isFalse);
    });
  });

  group('assemblyInstanceFacesVisible', () {
    test('shaded and shaded+edges show filled faces', () {
      expect(assemblyInstanceFacesVisible(ViewportRenderMode.shaded, bodiesHidden: false), isTrue);
      expect(assemblyInstanceFacesVisible(ViewportRenderMode.shadedWithEdges, bodiesHidden: false), isTrue);
    });

    test('wireframe shows no filled faces (edges only)', () {
      expect(assemblyInstanceFacesVisible(ViewportRenderMode.wireframe, bodiesHidden: false), isFalse);
      expect(ViewportRenderMode.wireframe.showsEdges, isTrue);
    });

    test('hidden bodies show no filled faces in any mode', () {
      for (final mode in ViewportRenderMode.values) {
        expect(assemblyInstanceFacesVisible(mode, bodiesHidden: true), isFalse);
      }
    });
  });

  group('occurrenceInstanceTransformsDiffer', () {
    test('false when the highlighted occurrence has not moved, even in a new list', () {
      final before = [_instance(['a'], 0), _instance(['b'], 5)];
      final after = [_instance(['a'], 0), _instance(['b'], 5)];
      expect(occurrenceInstanceTransformsDiffer({'a'}, before, after), isFalse);
    });

    test('true when the highlighted occurrence moved', () {
      expect(
        occurrenceInstanceTransformsDiffer({'a'}, [_instance(['a'], 0)], [_instance(['a'], 25)]),
        isTrue,
      );
    });

    test('false when only an un-highlighted occurrence moved', () {
      expect(
        occurrenceInstanceTransformsDiffer(
          {'a'},
          [_instance(['a'], 0), _instance(['b'], 5)],
          [_instance(['a'], 0), _instance(['b'], 50)],
        ),
        isFalse,
      );
    });

    test('nested occurrence paths are matched by their joined key', () {
      expect(
        occurrenceInstanceTransformsDiffer({'a/b'}, [_instance(['a', 'b'], 0)], [_instance(['a', 'b'], 3)]),
        isTrue,
      );
    });

    test('true when the occurrence appears or disappears', () {
      expect(occurrenceInstanceTransformsDiffer({'a'}, const [], [_instance(['a'], 0)]), isTrue);
      expect(occurrenceInstanceTransformsDiffer({'a'}, [_instance(['a'], 0)], const []), isTrue);
    });

    test('false with nothing highlighted', () {
      expect(occurrenceInstanceTransformsDiffer(const {}, [_instance(['a'], 0)], [_instance(['a'], 9)]), isFalse);
    });
  });
}
