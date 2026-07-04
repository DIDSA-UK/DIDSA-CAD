import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/selection_actions.dart';
import 'package:didsa_cad_client/viewport3d/selection_hit_test.dart';

const _face0 = SelectionEntityRef(kind: SelectionEntityKind.face, id: 0);
const _edge0 = SelectionEntityRef(kind: SelectionEntityKind.edge, id: 0);
const _vertex0 = SelectionEntityRef(kind: SelectionEntityKind.vertex, id: 0);

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

    test('edges + vertices (no faces) offers the normal-to-edge plane option', () {
      final actions = contextActionsFor({_edge0, _vertex0});
      expect(actions, [const SelectionContextAction('Create Plane (Normal to Edge Through Vertex)')]);
    });

    test('faces + vertices (no edges) offers the parallel-to-face plane option', () {
      final actions = contextActionsFor({_face0, _vertex0});
      expect(actions, [const SelectionContextAction('Create Plane (Parallel to Face Through Vertex)')]);
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
}
