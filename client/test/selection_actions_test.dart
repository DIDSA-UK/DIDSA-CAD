import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/reference_planes.dart';
import 'package:didsa_cad_client/viewport3d/selection_actions.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

const _face0 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 0);
const _edge0 = SelectionEntityRef(kind: SelectionEntityKind.edge, id: 0);
const _vertex0 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 0);
const _planeXy = SelectionEntityRef(
  kind: SelectionEntityKind.referencePlane,
  referencePlaneKind: ReferencePlaneKind.xy,
);
const _planeXz = SelectionEntityRef(
  kind: SelectionEntityKind.referencePlane,
  referencePlaneKind: ReferencePlaneKind.xz,
);
const _createPlane1 = SelectionEntityRef(
  kind: SelectionEntityKind.createPlane,
  planeFeatureId: 'plane-1',
);

void main() {
  group('contextActionsFor', () {
    test('empty selection offers no actions', () {
      expect(contextActionsFor(const {}), isEmpty);
    });

    test('edges only offers Chamfer and Fillet', () {
      final actions = contextActionsFor({_edge0});
      expect(actions, [const SelectionContextAction('Chamfer'), const SelectionContextAction('Fillet')]);
    });

    test('C2: exactly one face alone offers a real, enabled Create Plane (offset-from-face)', () {
      final actions = contextActionsFor({_face0});
      expect(actions, [const SelectionContextAction('Create Plane', enabled: true)]);
    });

    test('C3: exactly two faces alone offers a real, enabled Create Plane (Midplane)', () {
      const face1 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 1);
      final actions = contextActionsFor({_face0, face1});
      expect(actions, [const SelectionContextAction('Create Plane (Midplane)', enabled: true)]);
    });

    test('three faces alone still offers only the disabled scaffolded Create Plane', () {
      const face1 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 1);
      const face2 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 2);
      final actions = contextActionsFor({_face0, face1, face2});
      expect(actions, [const SelectionContextAction('Create Plane')]);
      expect(actions.single.enabled, isFalse);
    });

    test('vertices only offers Create Plane', () {
      final actions = contextActionsFor({_vertex0});
      expect(actions, [const SelectionContextAction('Create Plane')]);
    });

    test(
      'C4: exactly one edge and one vertex offers a real, enabled Create Plane '
      '(Normal to Edge Through Vertex)',
      () {
        final actions = contextActionsFor({_edge0, _vertex0});
        expect(actions, [
          const SelectionContextAction('Create Plane (Normal to Edge Through Vertex)', enabled: true),
        ]);
      },
    );

    test(
      'C4: exactly one face and one vertex offers a real, enabled Create Plane '
      '(Parallel to Face Through Vertex)',
      () {
        final actions = contextActionsFor({_face0, _vertex0});
        expect(actions, [
          const SelectionContextAction('Create Plane (Parallel to Face Through Vertex)', enabled: true),
        ]);
      },
    );

    test('two edges + one vertex still offers only the disabled scaffolded normal-to-edge option', () {
      const edge1 = SelectionEntityRef(kind: SelectionEntityKind.edge, id: 1);
      final actions = contextActionsFor({_edge0, edge1, _vertex0});
      expect(actions, [const SelectionContextAction('Create Plane (Normal to Edge Through Vertex)')]);
      expect(actions.single.enabled, isFalse);
    });

    test('one edge + two vertices still offers only the disabled scaffolded normal-to-edge option', () {
      const vertex1 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 1);
      final actions = contextActionsFor({_edge0, _vertex0, vertex1});
      expect(actions, [const SelectionContextAction('Create Plane (Normal to Edge Through Vertex)')]);
      expect(actions.single.enabled, isFalse);
    });

    test('two faces + one vertex still offers only the disabled scaffolded parallel-to-face option', () {
      const face1 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 1);
      final actions = contextActionsFor({_face0, face1, _vertex0});
      expect(actions, [const SelectionContextAction('Create Plane (Parallel to Face Through Vertex)')]);
      expect(actions.single.enabled, isFalse);
    });

    test('edges + faces offers the full operation set', () {
      final actions = contextActionsFor({_edge0, _face0});
      expect(actions, [
        const SelectionContextAction('Create Plane'),
        const SelectionContextAction('Chamfer'),
        const SelectionContextAction('Fillet'),
      ]);
    });

    test('edges + faces + vertices also offers the full operation set', () {
      final actions = contextActionsFor({_edge0, _face0, _vertex0});
      expect(actions, [
        const SelectionContextAction('Create Plane'),
        const SelectionContextAction('Chamfer'),
        const SelectionContextAction('Fillet'),
      ]);
    });

    test('every scaffolded action is disabled', () {
      final actions = contextActionsFor({_edge0, _face0, _vertex0});
      expect(actions.every((a) => !a.enabled), isTrue);
    });
  });

  group('C2: contextActionsFor with sketch Point/Line entities', () {
    const line = SelectionEntityRef(
      kind: SelectionEntityKind.sketchLine,
      sketchFeatureId: 'f1',
      sketchEntityId: 'line-1',
    );
    const endpointPoint = SelectionEntityRef(
      kind: SelectionEntityKind.sketchPoint,
      sketchFeatureId: 'f1',
      sketchEntityId: 'point-1',
    );
    const otherPoint = SelectionEntityRef(
      kind: SelectionEntityKind.sketchPoint,
      sketchFeatureId: 'f1',
      sketchEntityId: 'point-2',
    );
    const differentFeaturePoint = SelectionEntityRef(
      kind: SelectionEntityKind.sketchPoint,
      sketchFeatureId: 'f2',
      sketchEntityId: 'point-1',
    );

    bool alwaysTrue(String sketchFeatureId, String lineId, String pointId) => true;
    bool alwaysFalse(String sketchFeatureId, String lineId, String pointId) => false;

    test('a Line + its own endpoint Point offers a real, enabled Create Plane', () {
      final actions = contextActionsFor({line, endpointPoint}, isPointOnLine: alwaysTrue);
      expect(actions, [const SelectionContextAction('Create Plane', enabled: true)]);
    });

    test('a Line + a Point that is not its endpoint offers nothing', () {
      final actions = contextActionsFor({line, otherPoint}, isPointOnLine: alwaysFalse);
      expect(actions, isEmpty);
    });

    test('no isPointOnLine callback supplied defaults to not-an-endpoint (offers nothing)', () {
      final actions = contextActionsFor({line, endpointPoint});
      expect(actions, isEmpty);
    });

    test('a Line + a Point from a different Sketch Feature offers nothing, regardless of the checker', () {
      final actions = contextActionsFor({line, differentFeaturePoint}, isPointOnLine: alwaysTrue);
      expect(actions, isEmpty);
    });

    test('a lone Sketch Point offers nothing', () {
      expect(contextActionsFor({endpointPoint}, isPointOnLine: alwaysTrue), isEmpty);
    });

    test('a lone Sketch Line offers nothing', () {
      expect(contextActionsFor({line}, isPointOnLine: alwaysTrue), isEmpty);
    });

    test('two Sketch Points and a Line offers nothing (not exactly one of each)', () {
      final actions = contextActionsFor({line, endpointPoint, otherPoint}, isPointOnLine: alwaysTrue);
      expect(actions, isEmpty);
    });

    test('a Sketch entity mixed with a Body sub-shape offers nothing', () {
      final actions = contextActionsFor({line, endpointPoint, _face0}, isPointOnLine: alwaysTrue);
      expect(actions, isEmpty);
    });

    test('a Body-only selection still suppresses everything even with sketch entities elsewhere unselected', () {
      const body = SelectionEntityRef(kind: SelectionEntityKind.body, bodyId: 'b1');
      expect(contextActionsFor({body}, isPointOnLine: alwaysTrue), isEmpty);
    });
  });

  group('C4: contextActionsFor Three Points', () {
    const vertex1 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 1);
    const vertex2 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 2);
    const point1 = SelectionEntityRef(
      kind: SelectionEntityKind.sketchPoint,
      sketchFeatureId: 'f1',
      sketchEntityId: 'point-1',
    );
    const point2 = SelectionEntityRef(
      kind: SelectionEntityKind.sketchPoint,
      sketchFeatureId: 'f1',
      sketchEntityId: 'point-2',
    );

    test('three Body Vertices offers a real, enabled Create Plane (Three Points)', () {
      final actions = contextActionsFor({_vertex0, vertex1, vertex2});
      expect(actions, [const SelectionContextAction('Create Plane (Three Points)', enabled: true)]);
    });

    test('three Sketch Points offers a real, enabled Create Plane (Three Points)', () {
      const point3 = SelectionEntityRef(
        kind: SelectionEntityKind.sketchPoint,
        sketchFeatureId: 'f1',
        sketchEntityId: 'point-3',
      );
      final actions = contextActionsFor({point1, point2, point3});
      expect(actions, [const SelectionContextAction('Create Plane (Three Points)', enabled: true)]);
    });

    test('a mix of Body Vertices and Sketch Points (still exactly three) offers Three Points too', () {
      final actions = contextActionsFor({_vertex0, vertex1, point1});
      expect(actions, [const SelectionContextAction('Create Plane (Three Points)', enabled: true)]);
    });

    test('two points (not three) offers nothing for the vertex case', () {
      final actions = contextActionsFor({_vertex0, vertex1});
      expect(actions, [const SelectionContextAction('Create Plane')]);
      expect(actions.single.enabled, isFalse);
    });

    test('four points (not exactly three) offers nothing for the all-vertex case', () {
      const vertex3 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 3);
      final actions = contextActionsFor({_vertex0, vertex1, vertex2, vertex3});
      expect(actions, [const SelectionContextAction('Create Plane')]);
      expect(actions.single.enabled, isFalse);
    });

    test('three points plus an unrelated face offers nothing', () {
      final actions = contextActionsFor({_vertex0, vertex1, point1, _face0});
      expect(actions, isEmpty);
    });
  });

  group('C5: contextActionsFor with referencePlane/createPlane entities', () {
    test('a lone fixed reference plane offers a real, enabled Create Plane (offset)', () {
      final actions = contextActionsFor({_planeXy});
      expect(actions, [const SelectionContextAction('Create Plane', enabled: true)]);
    });

    test('a lone existing Plane offers a real, enabled Create Plane (offset)', () {
      final actions = contextActionsFor({_createPlane1});
      expect(actions, [const SelectionContextAction('Create Plane', enabled: true)]);
    });

    test('two fixed reference planes offers a real, enabled Create Plane (Midplane)', () {
      final actions = contextActionsFor({_planeXy, _planeXz});
      expect(actions, [const SelectionContextAction('Create Plane (Midplane)', enabled: true)]);
    });

    test('a fixed reference plane + a Body face offers a real, enabled Create Plane (Midplane)', () {
      final actions = contextActionsFor({_planeXy, _face0});
      expect(actions, [const SelectionContextAction('Create Plane (Midplane)', enabled: true)]);
    });

    test('a fixed reference plane + an existing Plane offers a real, enabled Create Plane (Midplane)', () {
      final actions = contextActionsFor({_planeXy, _createPlane1});
      expect(actions, [const SelectionContextAction('Create Plane (Midplane)', enabled: true)]);
    });

    test(
      'a fixed reference plane + one Vertex offers a real, enabled Create Plane '
      '(Parallel to Face Through Vertex)',
      () {
        final actions = contextActionsFor({_planeXy, _vertex0});
        expect(actions, [
          const SelectionContextAction('Create Plane (Parallel to Face Through Vertex)', enabled: true),
        ]);
      },
    );

    test('a fixed reference plane mixed with an Edge falls through to the full operation set', () {
      // A plane never composes with Chamfer/Fillet - this only exercises
      // that `hasFace`/`hasEdge` (the Chamfer/Fillet gate) stay strictly
      // Body-only and are unaffected by a plane-like entity also being
      // present, same as they already are for a plain face + edge.
      final actions = contextActionsFor({_planeXy, _edge0, _face0});
      expect(actions, [
        const SelectionContextAction('Create Plane'),
        const SelectionContextAction('Chamfer'),
        const SelectionContextAction('Fillet'),
      ]);
    });
  });
}
