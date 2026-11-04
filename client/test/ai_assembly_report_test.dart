import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/ai/ai_assembly_report.dart';
import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';

OccurrenceDto _occ(String id, {String? ref, String? name}) => OccurrenceDto(
      id: id,
      externalRef: ref,
      nameOverride: name,
      transform: RigidTransformDto(translation: const [0, 0, 0], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0),
    );

ConstraintStatusDto _status(String json) => ConstraintStatusDto.fromJson({
      'status': {'F': 'fixed', 'H': 'fully_constrained', 'U': 'under_constrained', 'O': 'over_constrained'}[json[0]],
      'dof': int.parse(json.substring(1)),
    });

const _slideX = FreeMotionDto(kind: 'slide', direction: [1, 0, 0]);
const _slideY = FreeMotionDto(kind: 'slide', direction: [0, -1, 0]);
const _spinZ = FreeMotionDto(kind: 'spin', axis: [0, 0, 1], through: [0, 0, 0]);

void main() {
  test('ConstraintStatusDto reads free_motions, and an older response without them still parses', () {
    final dto = ConstraintStatusDto.fromJson({
      'status': 'under_constrained',
      'dof': 3,
      'free_motions': [
        {'kind': 'slide', 'direction': [1, 0, 0]},
        {'kind': 'spin', 'axis': [0, 0, 1], 'through': [7, 3, 0]},
        {'kind': 'screw', 'axis': [0, 1, 0], 'through': [0, 0, 0], 'pitch_per_turn': 2.5},
      ],
    });
    expect(dto.freeMotions.map((m) => m.kind), ['slide', 'spin', 'screw']);
    expect(dto.freeMotions[1].through, [7, 3, 0]);
    expect(dto.freeMotions[2].pitchPerTurn, 2.5);
    expect(ConstraintStatusDto.fromJson({'status': 'fixed', 'dof': 0}).freeMotions, isEmpty);
  });

  test('describeFreeMotion names axes, and gives a spin axis that is off the origin its point', () {
    expect(describeFreeMotion(_slideX), 'slide along x');
    expect(describeFreeMotion(_slideY), 'slide along y');
    expect(describeFreeMotion(_spinZ), 'spin about z');
    expect(describeFreeMotion(const FreeMotionDto(kind: 'spin', axis: [0, 0, 1], through: [7, 3.25, 0])),
        'spin about z (through (7, 3.25, 0))');
    expect(describeFreeMotion(const FreeMotionDto(kind: 'slide', direction: [0.6, 0, 0.8])), 'slide along (0.6, 0, 0.8)');
    expect(describeFreeMotion(const FreeMotionDto(kind: 'screw', axis: [0, 1, 0], through: [0, 0, 0], pitchPerTurn: 2.5)),
        'screw about y, 2.5 per turn');
  });

  group('buildCompletenessReport', () {
    final occurrences = [
      _occ('base', name: 'Base'),
      _occ('plate', ref: 'parts/PLATE_001.didsa'),
      _occ('wheel', name: 'Wheel'),
      _occ('stray', name: 'Stray'),
    ];
    final status = {
      'base': _status('F0'),
      'plate': ConstraintStatusDto(state: ConstraintState.underConstrained, dof: 3, freeMotions: const [_slideX, _slideY, _spinZ]),
      'wheel': ConstraintStatusDto(state: ConstraintState.underConstrained, dof: 1, freeMotions: const [_spinZ]),
      // 'stray' is missing: the backend could not resolve its mates.
    };

    test('a free component with no declared intent needs a follow-up; one declared intended does not', () {
      final report = buildCompletenessReport(
        occurrences: occurrences,
        status: status,
        intended: const [AiIntendedMotion(component: 'existing:wheel', motion: 'spins on its axle')],
      );
      expect(report.unintendedlyFree.map((r) => r.occurrenceId), ['plate']);
      expect(report.needsFollowUp, isTrue);
      expect(report.rows[2].intendedMotion, 'spins on its axle');
      expect(report.isComplete, isFalse);

      final declared = buildCompletenessReport(
        occurrences: occurrences,
        status: status,
        intended: const [
          AiIntendedMotion(component: 'existing:wheel', motion: 'spins on its axle'),
          AiIntendedMotion(component: 'PLATE_001', motion: 'slides'), // by file name, any case
        ],
      );
      expect(declared.needsFollowUp, isFalse);
    });

    test('an intended motion matches by real id, existing: form, name or file name; an unknown name is ignored', () {
      for (final name in ['wheel', 'existing:wheel', 'Wheel', 'WHEEL']) {
        final report = buildCompletenessReport(
          occurrences: occurrences,
          status: status,
          intended: [AiIntendedMotion(component: name, motion: 'm')],
        );
        expect(report.rows[2].intendedMotion, 'm', reason: name);
      }
      final ignored = buildCompletenessReport(
        occurrences: occurrences,
        status: status,
        intended: const [AiIntendedMotion(component: 'ghost', motion: 'm')],
      );
      expect(ignored.rows.every((r) => r.intendedMotion == null), isTrue);
    });

    test('an over-constrained component is reported but never triggers a follow-up by itself', () {
      final report = buildCompletenessReport(
        occurrences: [_occ('a', name: 'A')],
        status: {'a': _status('O1')},
      );
      expect(report.needsFollowUp, isFalse);
      expect(report.overConstrained, hasLength(1));
      expect(formatCompletenessReport(report), contains('over-constrained'));
    });

    test('the text says what each component can still do, in its own words', () {
      final report = buildCompletenessReport(
        occurrences: occurrences,
        status: status,
        intended: const [AiIntendedMotion(component: 'wheel', motion: 'spins on its axle')],
      );
      final text = formatCompletenessReport(report);
      expect(text, contains('- Base: fixed'));
      expect(text, contains('- parts/PLATE_001.didsa: free to move: slide along x, slide along y, spin about z (any mix)'));
      expect(text, contains('- Wheel: free to spin about z (meant to move: "spins on its axle")'));
      expect(text, contains('- Stray: not checked'));
      expect(formatFreeComponentsForPrompt(report.unintendedlyFree),
          'existing:plate - parts/PLATE_001.didsa: free to move: slide along x, slide along y, spin about z (any mix)');
    });

    test('a group held against itself but not to a fixed component says so (dof 0 and under-constrained)', () {
      final report = buildCompletenessReport(occurrences: [_occ('a', name: 'A')], status: {'a': _status('U0')});
      expect(formatCompletenessReport(report), contains('not to a fixed component'));
    });

    test('a large assembly lists only the components that need attention, and counts the rest', () {
      final many = [for (var i = 0; i < 20; i++) _occ('o$i', name: 'Part $i')];
      final report = buildCompletenessReport(
        occurrences: many,
        status: {
          for (var i = 0; i < 20; i++) 'o$i': i == 7 ? ConstraintStatusDto(state: ConstraintState.underConstrained, dof: 1, freeMotions: const [_spinZ]) : _status('H0'),
        },
      );
      final lines = formatCompletenessReport(report).split('\n');
      expect(lines, hasLength(2));
      expect(lines.first, contains('Part 7'));
      expect(lines.last, '- 19 of 20 components are fixed or fully constrained.');
    });
  });
}
