import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/assembly/occurrence_visibility.dart';
import 'package:didsa_cad_client/viewport3d/width_pick.dart';
import 'package:flutter_test/flutter_test.dart';

/// F1 of `docs/pattern-followers-and-dissolve-plan.md`: a mate on a pattern copy is, for "is this part mated", a mate on the
/// copy's SOURCE (the client mirror of the backend's `mate_ref_drivers`).
MateDto _mate(List<String> ids) => MateDto(
      id: 'm',
      type: 'coincident',
      references: [
        for (final id in ids) MateEntityRefDto(occurrenceId: id),
      ],
    );

void main() {
  test('mateDrivingOccurrenceId folds a copy segment to its source and a path to its top', () {
    expect(mateDrivingOccurrenceId('A'), 'A');
    expect(mateDrivingOccurrenceId('A#pattern:P:1'), 'A');
    expect(mateDrivingOccurrenceId('S/A#pattern:P:1'), 'S');
    expect(mateDrivingOccurrenceId('S#pattern:P:2/inner'), 'S');
    expect(mateDrivingOccurrenceId(''), '');
  });

  test('a mate on a copy marks the source mated, never the copy id', () {
    final tops = mateTopLevelOccurrences(_mate(['B', 'A#pattern:P:1']));
    expect(tops, {'A', 'B'});
    expect(tops.any((t) => t.contains('#')), isFalse);
  });

  test('a nested copy marks the sub-assembly that carries it', () {
    expect(mateTopLevelOccurrences(_mate(['B', 'S/A#pattern:P:1'])), {'S', 'B'});
  });

  test('a Width mid-plane whose second face is on a copy marks that copy\'s source', () {
    final width = MateDto(
      id: 'w',
      type: 'coincident',
      references: [
        MateEntityRefDto(
          occurrenceId: 'barL',
          midplane: MidplaneRefDto(
            a: PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'b', shapeType: 'face', index: 0)),
            b: PlaneRefDto(faceRef: SubShapeRefDto(bodyId: 'b', shapeType: 'face', index: 1)),
            bOccurrenceId: 'barR#pattern:P:3',
          ),
        ),
        MateEntityRefDto(occurrenceId: 'plate'),
      ],
    );
    expect(mateTopLevelOccurrences(width), {'barL', 'barR', 'plate'});
  });

  test('MateDto.status reads ok / broken and defaults to ok for an older backend', () {
    final base = {
      'id': 'm',
      'type': 'coincident',
      'references': [
        {'occurrence_id': 'a'},
        {'occurrence_id': 'b'},
      ],
    };
    expect(MateDto.fromJson(base).status, 'ok');
    expect(MateDto.fromJson(base).isBroken, isFalse);
    expect(MateDto.fromJson({...base, 'status': 'broken'}).isBroken, isTrue);
  });

  test('ComponentPatternDto carries a PATCH response\'s broken_mate_ids', () {
    final json = {
      'id': 'p',
      'source_occurrence_ids': ['a'],
      'pattern_type': 'linear',
      'direction': [1.0, 0.0, 0.0],
      'broken_mate_ids': ['m1', 'm2'],
    };
    expect(ComponentPatternDto.fromJson(json).brokenMateIds, ['m1', 'm2']);
    expect(ComponentPatternDto.fromJson({...json}..remove('broken_mate_ids')).brokenMateIds, isEmpty);
  });
}
