import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/viewport3d/selection_filter.dart';

void main() {
  group('SelectionFilterState.defaults', () {
    test('vertex, edge, and face default on; body defaults off', () {
      const state = SelectionFilterState.defaults;
      expect(state.vertex, isTrue);
      expect(state.edge, isTrue);
      expect(state.face, isTrue);
      expect(state.body, isFalse);
    });
  });

  group('SelectionFilterState.copyWith', () {
    test('changes only the specified field, leaving the rest untouched', () {
      const state = SelectionFilterState.defaults;
      final next = state.copyWith(vertex: false);
      expect(next.vertex, isFalse);
      expect(next.edge, isTrue);
      expect(next.face, isTrue);
      expect(next.body, isFalse);
    });

    test('omitted fields keep their current value, not a default', () {
      const state = SelectionFilterState(vertex: false, edge: false, face: true, body: true);
      final next = state.copyWith(face: false);
      expect(next.vertex, isFalse);
      expect(next.edge, isFalse);
      expect(next.face, isFalse);
      expect(next.body, isTrue);
    });

    test('every field can be set independently in one call', () {
      const state = SelectionFilterState.defaults;
      final next = state.copyWith(vertex: false, edge: false, face: false, body: true);
      expect(next, const SelectionFilterState(vertex: false, edge: false, face: false, body: true));
    });
  });

  group('SelectionFilterState equality', () {
    test('two states with the same fields are equal', () {
      const a = SelectionFilterState(vertex: true, edge: false, face: true, body: false);
      const b = SelectionFilterState(vertex: true, edge: false, face: true, body: false);
      expect(a, b);
      expect(a.hashCode, b.hashCode);
    });

    test('states differing in any single field are not equal', () {
      const base = SelectionFilterState(vertex: true, edge: true, face: true, body: false);
      expect(base, isNot(base.copyWith(vertex: false)));
      expect(base, isNot(base.copyWith(edge: false)));
      expect(base, isNot(base.copyWith(face: false)));
      expect(base, isNot(base.copyWith(body: true)));
    });
  });
}
