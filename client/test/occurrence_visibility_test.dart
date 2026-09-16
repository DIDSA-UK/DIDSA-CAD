import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/occurrence_visibility.dart';

RigidTransformDto _identity() =>
    RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0);

OccurrenceDto _occurrence(String id, {bool hidden = false}) => OccurrenceDto(
      id: id,
      transform: _identity(),
      hidden: hidden,
    );

void main() {
  group('applyOccurrenceVisibilityOverrides', () {
    test('an Occurrence with no overrides at all keeps its own hidden value unchanged', () {
      final result = applyOccurrenceVisibilityOverrides(
        [_occurrence('a', hidden: false), _occurrence('b', hidden: true)],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: null,
      );
      expect(result.map((o) => o.hidden), [false, true]);
    });

    test('an id in hiddenOccurrenceIds becomes hidden, others are untouched', () {
      final result = applyOccurrenceVisibilityOverrides(
        [_occurrence('a'), _occurrence('b'), _occurrence('c')],
        hiddenOccurrenceIds: const {'b'},
        isolatedOccurrenceId: null,
      );
      expect(result.map((o) => o.hidden), [false, true, false]);
    });

    test('isolatedOccurrenceId hides every other Occurrence, leaving the isolated one alone', () {
      final result = applyOccurrenceVisibilityOverrides(
        [_occurrence('a'), _occurrence('b'), _occurrence('c')],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: 'b',
      );
      expect(result.map((o) => o.hidden), [true, false, true]);
    });

    test('hiddenOccurrenceIds and isolatedOccurrenceId compose - the isolated one can still be independently hidden', () {
      final result = applyOccurrenceVisibilityOverrides(
        [_occurrence('a'), _occurrence('b')],
        hiddenOccurrenceIds: const {'b'},
        isolatedOccurrenceId: 'b',
      );
      expect(result.map((o) => o.hidden), [true, true]);
    });

    test(
        'an Occurrence already hidden by the backend stays hidden regardless of overrides - '
        'there is no mutation endpoint to ever un-hide it client-side', () {
      final result = applyOccurrenceVisibilityOverrides(
        [_occurrence('a', hidden: true)],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: 'a',
      );
      expect(result.single.hidden, isTrue);
    });

    test('never mutates the input list - returns fresh OccurrenceDto instances', () {
      final input = [_occurrence('a')];
      final result = applyOccurrenceVisibilityOverrides(
        input,
        hiddenOccurrenceIds: const {'a'},
        isolatedOccurrenceId: null,
      );
      expect(input.single.hidden, isFalse);
      expect(result.single.hidden, isTrue);
    });

    test('an empty occurrences list returns an empty list', () {
      final result = applyOccurrenceVisibilityOverrides(
        const [],
        hiddenOccurrenceIds: const {'a'},
        isolatedOccurrenceId: 'a',
      );
      expect(result, isEmpty);
    });
  });

  group('applyInstanceVisibilityOverrides', () {
    AssemblyOccurrenceInstanceDto instance(List<String> path, {bool hidden = false}) =>
        AssemblyOccurrenceInstanceDto(
          occurrencePath: path,
          partId: 'part-${path.isEmpty ? "root" : path.last}',
          worldTransform: _identity(),
          hidden: hidden,
        );

    test('an instance with no overrides at all keeps its own hidden value unchanged', () {
      final result = applyInstanceVisibilityOverrides(
        [instance(const ['a']), instance(const ['b'], hidden: true)],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: null,
      );
      expect(result.map((i) => i.hidden), [false, true]);
    });

    test('hiding a top-level Occurrence also hides an instance nested underneath it', () {
      final result = applyInstanceVisibilityOverrides(
        [instance(const ['a']), instance(const ['a', 'nested'])],
        hiddenOccurrenceIds: const {'a'},
        isolatedOccurrenceId: null,
      );
      expect(result.map((i) => i.hidden), [true, true]);
    });

    test('hiding a nested Occurrence does not hide its own parent instance', () {
      final result = applyInstanceVisibilityOverrides(
        [instance(const ['a']), instance(const ['a', 'nested'])],
        hiddenOccurrenceIds: const {'nested'},
        isolatedOccurrenceId: null,
      );
      expect(result.map((i) => i.hidden), [false, true]);
    });

    test('isolating a top-level Occurrence keeps it and its own nested contents visible, hides every peer', () {
      final result = applyInstanceVisibilityOverrides(
        [instance(const ['a']), instance(const ['a', 'nested']), instance(const ['b'])],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: 'a',
      );
      expect(result.map((i) => i.hidden), [false, false, true]);
    });

    test('an instance already hidden by the backend stays hidden regardless of overrides', () {
      final result = applyInstanceVisibilityOverrides(
        [instance(const ['a'], hidden: true)],
        hiddenOccurrenceIds: const {},
        isolatedOccurrenceId: 'a',
      );
      expect(result.single.hidden, isTrue);
    });

    test('an empty instances list returns an empty list', () {
      final result = applyInstanceVisibilityOverrides(
        const [],
        hiddenOccurrenceIds: const {'a'},
        isolatedOccurrenceId: 'a',
      );
      expect(result, isEmpty);
    });
  });

  // Phase 4 fix (`docs/assembly-scope.md` §5 appendix item 4, resolved):
  // the "and its children" half of "focus part and its children opaque,
  // peers and parents translucent" - a plain list-prefix check.
  group('isOccurrencePathWithinFocus', () {
    test('an empty focusedOccurrencePath (nothing focused) never matches anything', () {
      expect(isOccurrencePathWithinFocus(const [], const []), isFalse);
      expect(isOccurrencePathWithinFocus(const ['a'], const []), isFalse);
    });

    test('the focused Occurrence\'s own exact path matches', () {
      expect(isOccurrencePathWithinFocus(const ['a'], const ['a']), isTrue);
      expect(isOccurrencePathWithinFocus(const ['a', 'b'], const ['a', 'b']), isTrue);
    });

    test('an instance nested inside the focused Occurrence matches', () {
      expect(isOccurrencePathWithinFocus(const ['a', 'child'], const ['a']), isTrue);
      expect(isOccurrencePathWithinFocus(const ['a', 'child', 'grandchild'], const ['a']), isTrue);
    });

    test('a peer of the focused Occurrence does not match', () {
      expect(isOccurrencePathWithinFocus(const ['b'], const ['a']), isFalse);
    });

    test('a parent of the focused Occurrence does not match', () {
      expect(isOccurrencePathWithinFocus(const ['a'], const ['a', 'child']), isFalse);
    });

    test('a sibling nested one level deeper (shared prefix, different leaf) does not match', () {
      expect(isOccurrencePathWithinFocus(const ['a', 'sibling'], const ['a', 'child']), isFalse);
    });

    test('an unrelated multi-segment path sharing no prefix does not match', () {
      expect(isOccurrencePathWithinFocus(const ['x', 'y', 'z'], const ['a', 'b']), isFalse);
    });
  });

  // Assembly support Phase 12 (`docs/assembly-scope.md` §6 `[18]`):
  // isOccurrencePathWithinFocus's stricter sibling - exactly one level
  // below the focused path, not any depth.
  group('isDirectChildOfFocus', () {
    test('an empty focusedOccurrencePath treats a top-level path as a direct child', () {
      expect(isDirectChildOfFocus(const ['a'], const []), isTrue);
    });

    test('an empty focusedOccurrencePath rejects an empty path (nothing to be a child of itself)', () {
      expect(isDirectChildOfFocus(const [], const []), isFalse);
    });

    test('exactly one level below the focused path matches', () {
      expect(isDirectChildOfFocus(const ['a', 'child'], const ['a']), isTrue);
    });

    test('the focused path\'s own exact path (zero levels deeper) does not match', () {
      expect(isDirectChildOfFocus(const ['a'], const ['a']), isFalse);
    });

    test('two levels below the focused path (a grandchild) does not match', () {
      expect(isDirectChildOfFocus(const ['a', 'child', 'grandchild'], const ['a']), isFalse);
    });

    test('a peer of the focused path does not match', () {
      expect(isDirectChildOfFocus(const ['b', 'child'], const ['a']), isFalse);
    });

    test('a shorter path than the focused one does not match', () {
      expect(isDirectChildOfFocus(const ['a'], const ['a', 'child']), isFalse);
    });
  });

  // Assembly support Phase 12: the exact-path lookup PartScreen's own
  // nested live-drag overlay needs to find the focused sub-assembly's own
  // current placed instance.
  group('findInstanceAtPath', () {
    AssemblyOccurrenceInstanceDto instance(List<String> path) => AssemblyOccurrenceInstanceDto(
          occurrencePath: path,
          partId: 'part-${path.isEmpty ? "root" : path.last}',
          worldTransform: _identity(),
        );

    test('finds the instance whose occurrencePath exactly matches', () {
      final instances = [instance(const ['a']), instance(const ['a', 'child'])];
      final found = findInstanceAtPath(instances, const ['a', 'child']);
      expect(found, same(instances[1]));
    });

    test('returns null when no instance matches', () {
      final instances = [instance(const ['a'])];
      expect(findInstanceAtPath(instances, const ['does-not-exist']), isNull);
    });

    test('returns null for an empty instances list', () {
      expect(findInstanceAtPath(const [], const ['a']), isNull);
    });
  });

  // Assembly support Phase 5: the Move/Rotate gizmo's own live-drag
  // overlay - an exact-path match, unlike isOccurrencePathWithinFocus's
  // prefix match.
  group('overrideInstanceTransform', () {
    AssemblyOccurrenceInstanceDto instance(List<String> path) => AssemblyOccurrenceInstanceDto(
          occurrencePath: path,
          partId: 'part-${path.isEmpty ? "root" : path.last}',
          worldTransform: _identity(),
        );

    RigidTransformDto dragged() =>
        RigidTransformDto(translation: const [9, 9, 9], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 45);

    test('overrides only the instance whose occurrencePath exactly matches', () {
      final result = overrideInstanceTransform(
        [instance(const ['a']), instance(const ['b'])],
        targetOccurrencePath: const ['a'],
        transform: dragged(),
      );
      expect(result[0].worldTransform, dragged());
      expect(result[1].worldTransform, _identity());
    });

    test('does not override an instance nested inside the target path', () {
      // A child's own placement is relative to its parent - it moves along
      // automatically once the parent's world transform is recomposed, so
      // overriding it here directly would be wrong, not just redundant.
      final result = overrideInstanceTransform(
        [instance(const ['a']), instance(const ['a', 'child'])],
        targetOccurrencePath: const ['a'],
        transform: dragged(),
      );
      expect(result[0].worldTransform, dragged());
      expect(result[1].worldTransform, _identity());
    });

    test('does not override the target\'s own parent', () {
      final result = overrideInstanceTransform(
        [instance(const ['a']), instance(const ['a', 'child'])],
        targetOccurrencePath: const ['a', 'child'],
        transform: dragged(),
      );
      expect(result[0].worldTransform, _identity());
      expect(result[1].worldTransform, dragged());
    });

    test('a target path matching no instance at all leaves every instance untouched', () {
      final result = overrideInstanceTransform(
        [instance(const ['a']), instance(const ['b'])],
        targetOccurrencePath: const ['does-not-exist'],
        transform: dragged(),
      );
      expect(result[0].worldTransform, _identity());
      expect(result[1].worldTransform, _identity());
    });

    test('an empty instances list returns an empty list', () {
      final result = overrideInstanceTransform(
        const [],
        targetOccurrencePath: const ['a'],
        transform: dragged(),
      );
      expect(result, isEmpty);
    });
  });
}
