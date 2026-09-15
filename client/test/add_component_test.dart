import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/assembly/add_component.dart';

Map<String, dynamic> _documentPayload({
  required List<Map<String, dynamic>> parts,
  required String rootPartId,
}) {
  return {
    'schema_version': 1,
    'document': {
      'id': 'doc-1',
      'root_part_id': rootPartId,
      'parts': parts,
    },
    'sketches': [],
  };
}

Map<String, dynamic> _part(String id, {List<Map<String, dynamic>>? occurrences}) {
  return {
    'id': id,
    'name': 'Part $id',
    'features': [],
    'part_number': null,
    'description': null,
    'revision': null,
    'remarks': null,
    'supplier': null,
    'supplier_part_number': null,
    'default_material': null,
    'body_material_assignments': <String, dynamic>{},
    'occurrences': occurrences ?? [],
    'mates': [],
  };
}

void main() {
  group('mergeComponentIntoDocument', () {
    test('adds a new Occurrence on the current root Part and appends the incoming Part', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = _documentPayload(parts: [_part('bolt')], rootPartId: 'bolt');

      final merged = mergeComponentIntoDocument(
        currentPayload: current,
        componentPayload: component,
        rootPartId: 'root',
        occurrenceId: 'occ-1',
        externalRef: 'bolt.didsa',
        nameOverride: null,
      );

      final parts = (merged['document']['parts'] as List).cast<Map<String, dynamic>>();
      expect(parts.map((p) => p['id']), containsAll(['root', 'bolt']));

      final root = parts.firstWhere((p) => p['id'] == 'root');
      final occurrences = (root['occurrences'] as List).cast<Map<String, dynamic>>();
      expect(occurrences, hasLength(1));
      expect(occurrences.single['id'], 'occ-1');
      expect(occurrences.single['resolved_part_id'], 'bolt');
      expect(occurrences.single['external_ref'], 'bolt.didsa');
      expect(occurrences.single['suppressed'], false);
      expect(occurrences.single['hidden'], false);
    });

    test('preserves existing Occurrences on the root Part rather than replacing them', () {
      final existingOccurrence = {
        'id': 'occ-existing',
        'external_ref': 'washer.didsa',
        'resolved_part_id': 'washer',
        'name_override': null,
        'transform': null,
        'suppressed': false,
        'hidden': false,
      };
      final current = _documentPayload(
        parts: [_part('root', occurrences: [existingOccurrence]), _part('washer')],
        rootPartId: 'root',
      );
      final component = _documentPayload(parts: [_part('bolt')], rootPartId: 'bolt');

      final merged = mergeComponentIntoDocument(
        currentPayload: current,
        componentPayload: component,
        rootPartId: 'root',
        occurrenceId: 'occ-new',
        externalRef: 'bolt.didsa',
      );

      final root = (merged['document']['parts'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == 'root');
      final occurrenceIds = (root['occurrences'] as List)
          .cast<Map<String, dynamic>>()
          .map((o) => o['id']);
      expect(occurrenceIds, containsAll(['occ-existing', 'occ-new']));
    });

    test('inserting the same file twice dedups by the incoming Part id, not two Part entries', () {
      final current = _documentPayload(
        parts: [_part('root', occurrences: [
          {
            'id': 'occ-1',
            'external_ref': 'bolt.didsa',
            'resolved_part_id': 'bolt',
            'name_override': null,
            'transform': null,
            'suppressed': false,
            'hidden': false,
          },
        ]), _part('bolt')],
        rootPartId: 'root',
      );
      final component = _documentPayload(parts: [_part('bolt')], rootPartId: 'bolt');

      final merged = mergeComponentIntoDocument(
        currentPayload: current,
        componentPayload: component,
        rootPartId: 'root',
        occurrenceId: 'occ-2',
        externalRef: 'bolt.didsa',
      );

      final parts = (merged['document']['parts'] as List).cast<Map<String, dynamic>>();
      expect(parts.where((p) => p['id'] == 'bolt'), hasLength(1));
      final root = parts.firstWhere((p) => p['id'] == 'root');
      expect((root['occurrences'] as List), hasLength(2));
    });

    test('falls back to the incoming file\'s first Part when it has no root_part_id', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = {
        'schema_version': 1,
        'document': {
          'id': 'doc-2',
          'root_part_id': null,
          'parts': [_part('legacy')],
        },
        'sketches': [],
      };

      final merged = mergeComponentIntoDocument(
        currentPayload: current,
        componentPayload: component,
        rootPartId: 'root',
        occurrenceId: 'occ-1',
      );

      final root = (merged['document']['parts'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == 'root');
      final occurrence = (root['occurrences'] as List).cast<Map<String, dynamic>>().single;
      expect(occurrence['resolved_part_id'], 'legacy');
    });

    test('throws for a mismatched schema_version', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = {
        'schema_version': 2,
        'document': {'id': 'doc-2', 'root_part_id': 'bolt', 'parts': [_part('bolt')]},
        'sketches': [],
      };

      expect(
        () => mergeComponentIntoDocument(
          currentPayload: current,
          componentPayload: component,
          rootPartId: 'root',
          occurrenceId: 'occ-1',
        ),
        throwsA(isA<AddComponentException>()),
      );
    });

    test('throws for a file with no Parts at all', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = _documentPayload(parts: const [], rootPartId: 'root');

      expect(
        () => mergeComponentIntoDocument(
          currentPayload: current,
          componentPayload: component,
          rootPartId: 'root',
          occurrenceId: 'occ-1',
        ),
        throwsA(isA<AddComponentException>()),
      );
    });

    test('throws when the picked file is the currently-open Part itself (self-reference)', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = _documentPayload(parts: [_part('root')], rootPartId: 'root');

      expect(
        () => mergeComponentIntoDocument(
          currentPayload: current,
          componentPayload: component,
          rootPartId: 'root',
          occurrenceId: 'occ-1',
        ),
        throwsA(isA<AddComponentException>()),
      );
    });

    test('throws when rootPartId is not actually present in the current session snapshot', () {
      final current = _documentPayload(parts: [_part('other')], rootPartId: 'other');
      final component = _documentPayload(parts: [_part('bolt')], rootPartId: 'bolt');

      expect(
        () => mergeComponentIntoDocument(
          currentPayload: current,
          componentPayload: component,
          rootPartId: 'root',
          occurrenceId: 'occ-1',
        ),
        throwsA(isA<AddComponentException>()),
      );
    });

    test('carries a nameOverride through onto the new Occurrence', () {
      final current = _documentPayload(parts: [_part('root')], rootPartId: 'root');
      final component = _documentPayload(parts: [_part('bolt')], rootPartId: 'bolt');

      final merged = mergeComponentIntoDocument(
        currentPayload: current,
        componentPayload: component,
        rootPartId: 'root',
        occurrenceId: 'occ-1',
        nameOverride: 'Main bolt',
      );

      final root = (merged['document']['parts'] as List)
          .cast<Map<String, dynamic>>()
          .firstWhere((p) => p['id'] == 'root');
      final occurrence = (root['occurrences'] as List).cast<Map<String, dynamic>>().single;
      expect(occurrence['name_override'], 'Main bolt');
    });
  });
}
