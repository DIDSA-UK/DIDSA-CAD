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
      expect(actions, [const ContextAction('Chamfer'), const ContextAction('Fillet')]);
    });

    test('faces only offers Create Plane', () {
      final actions = contextActionsFor({_face0});
      expect(actions, [const ContextAction('Create Plane')]);
    });

    test('vertices only offers Create Plane', () {
      final actions = contextActionsFor({_vertex0});
      expect(actions, [const ContextAction('Create Plane')]);
    });

    test('edges + vertices (no faces) offers the normal-to-edge plane option', () {
      final actions = contextActionsFor({_edge0, _vertex0});
      expect(actions, [const ContextAction('Create Plane (Normal to Edge Through Vertex)')]);
    });

    test('faces + vertices (no edges) offers the parallel-to-face plane option', () {
      final actions = contextActionsFor({_face0, _vertex0});
      expect(actions, [const ContextAction('Create Plane (Parallel to Face Through Vertex)')]);
    });

    test('edges + faces offers the full operation set', () {
      final actions = contextActionsFor({_edge0, _face0});
      expect(actions, [
        const ContextAction('Create Plane'),
        const ContextAction('Chamfer'),
        const ContextAction('Fillet'),
      ]);
    });

    test('edges + faces + vertices also offers the full operation set', () {
      final actions = contextActionsFor({_edge0, _face0, _vertex0});
      expect(actions, [
        const ContextAction('Create Plane'),
        const ContextAction('Chamfer'),
        const ContextAction('Fillet'),
      ]);
    });

    test('every scaffolded action is disabled', () {
      final actions = contextActionsFor({_edge0, _face0, _vertex0});
      expect(actions.every((a) => !a.enabled), isTrue);
    });
  });
}
