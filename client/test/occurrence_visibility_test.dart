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
}
