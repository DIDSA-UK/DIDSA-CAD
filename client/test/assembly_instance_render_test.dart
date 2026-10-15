import 'package:flutter_test/flutter_test.dart';
import 'package:vector_math/vector_math.dart' as vm;

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

  group('matePreviewGhosts', () {
    RigidTransformDto at(double x, [double y = 0, double z = 0]) =>
        RigidTransformDto(translation: [x, y, z], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

    AssemblyOccurrenceInstanceDto instance(List<String> path, double x, {bool hidden = false}) => AssemblyOccurrenceInstanceDto(
          occurrencePath: path,
          partId: 'p-${path.last}',
          worldTransform: at(x),
          hidden: hidden,
        );

    vm.Vector3 origin(MatePreviewGhost g) => g.world.getTranslation();

    test('a driven occurrence is ghosted at its solved pose', () {
      final ghosts = matePreviewGhosts(
        instances: [instance(['a'], 0), instance(['b'], 50)],
        members: [MatePreviewMember(occurrenceId: 'a', previous: at(0), next: at(7, 2, 3))],
      );
      expect(ghosts.map((g) => g.instance.occurrencePath), [
        ['a'],
      ]);
      expect(origin(ghosts.single).storage, [7.0, 2.0, 3.0]);
    });

    test('a sub-assembly is ghosted through its nested leaf instances, each moved by the same world change', () {
      // `frame` has no bodies of its own: its bars are the nested instances, one placed 10 mm and one 30 mm from it.
      final ghosts = matePreviewGhosts(
        instances: [instance(['frame'], 100), instance(['frame', 'bar1'], 110), instance(['frame', 'bar2'], 130), instance(['other'], 0)],
        members: [MatePreviewMember(occurrenceId: 'frame', previous: at(100), next: at(140))],
      );
      expect(ghosts.map((g) => g.instance.occurrencePath.join('/')), ['frame', 'frame/bar1', 'frame/bar2']);
      expect(ghosts.map((g) => origin(g).x), [140.0, 150.0, 170.0]);
    });

    test('followers are ghosted alongside the driven occurrence', () {
      final ghosts = matePreviewGhosts(
        instances: [instance(['a'], 0), instance(['b'], 20)],
        members: [
          MatePreviewMember(occurrenceId: 'a', previous: at(0), next: at(5)),
          MatePreviewMember(occurrenceId: 'b', previous: at(20), next: at(26)),
        ],
      );
      expect(ghosts.map((g) => origin(g).x), [5.0, 26.0]);
    });

    test('a hidden instance and an instance of an unrelated occurrence are not ghosted', () {
      final ghosts = matePreviewGhosts(
        instances: [instance(['a'], 0, hidden: true), instance(['ab'], 0)],
        members: [MatePreviewMember(occurrenceId: 'a', previous: at(0), next: at(5))],
      );
      expect(ghosts, isEmpty);
    });

    test('while focused, previous/next are local to the focused part and the ghost lands at the right world place', () {
      // Focused occurrence `outer` sits at x=1000; its child `a` is local x=10 -> world 1010, and moves to local x=25.
      final ghosts = matePreviewGhosts(
        instances: [instance(['outer'], 1000), instance(['outer', 'a'], 1010), instance(['outer', 'b'], 1050)],
        members: [MatePreviewMember(occurrenceId: 'a', previous: at(10), next: at(25))],
        focusedPath: const ['outer'],
        focusWorld: vm.Matrix4.translationValues(1000, 0, 0),
      );
      expect(ghosts.map((g) => g.instance.occurrencePath.join('/')), ['outer/a']);
      expect(origin(ghosts.single).x, closeTo(1025.0, 1e-9));
    });

    test('a rotation of the occurrence rotates its nested instances about the occurrence origin', () {
      final turned = RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 90);
      final ghosts = matePreviewGhosts(
        instances: [instance(['frame'], 0), instance(['frame', 'bar'], 10)],
        members: [MatePreviewMember(occurrenceId: 'frame', previous: at(0), next: turned)],
      );
      final bar = ghosts.firstWhere((g) => g.instance.occurrencePath.length == 2);
      expect(origin(bar).x, closeTo(0.0, 1e-5));
      expect(origin(bar).y, closeTo(10.0, 1e-5));
    });
  });
}
