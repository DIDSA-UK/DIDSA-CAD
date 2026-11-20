// The rigidity analysis's vectors (docs/sketch-rigidity-vectors.json; spec: docs/sketch-rigidity-spec.md).
//
//   flutter test test/sketch_rigidity_vectors_test.dart                              # check (also part of the full suite)
//   DIDSA_RIGIDITY_VECTORS=write flutter test test/sketch_rigidity_vectors_test.dart # (re)write the file
//   tools/sketch_vectors/export_rigidity.sh [--check]                                # the same, from the repo root
//
// Check mode fails when a regeneration differs from the committed file, when SketchRigidity.analyze does not reproduce a
// case from its JSON alone, or when a case's own assertions (copied from dof_analysis_test.dart) do not hold.
import 'dart:convert';
import 'dart:io';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/sketch/dof_analysis.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support/sketch_rigidity_cases.dart';
import 'support/sketch_vectors.dart' show constraintToWire, encodeSketchVectors, sketchVectorDifferences;

const _path = '../docs/sketch-rigidity-vectors.json';

SketchRigidity _run(
  List<String> pointIds,
  Set<String> fixed,
  Map<String, (String, String)> lines,
  List<ConstraintDto> constraints,
  bool trust,
) =>
    SketchRigidity.analyze(
      pointIds: pointIds,
      fixedPointIds: fixed,
      lineStartPointId: {for (final e in lines.entries) e.key: e.value.$1},
      lineEndPointId: {for (final e in lines.entries) e.key: e.value.$2},
      constraints: constraints,
      trustConvergedSolve: trust,
    );

/// Every verdict for the points of [ids] (the case's points and its fixed points), and each entity's colour verdict.
Map<String, dynamic> _expected(
    SketchRigidity r, Iterable<String> ids, Map<String, Map<String, List<String>>> entities) {
  final all = ids.toSet().toList()..sort();
  List<String> where(bool Function(String) f) => [
        for (final id in all)
          if (f(id)) id
      ];
  String verdict(List<String> pts) {
    // The canvas's per-entity rule over the entity's defining pairs (line: start-end; circle: centre-radius point;
    // arc: centre-start and centre-end), the rigidity part only (spec 4).
    final pairs = pts.length == 3 ? [(pts[0], pts[1]), (pts[0], pts[2])] : [(pts[0], pts[1])];
    if (pairs.any((p) => r.isSegmentOverConstrained(p.$1, p.$2))) return 'over';
    if (pairs.every((p) => r.isSegmentFullyConstrained(p.$1, p.$2))) return 'fully';
    return 'free';
  }

  return {
    'fully': where(r.isPointFullyConstrained),
    'over': where(r.isPointOverConstrained),
    'grounded': where(r.isPointGrounded),
    'pinned': where(r.isPointPinned),
    'any_grounded': r.isAnyPointGrounded,
    if (entities.isNotEmpty)
      'entities': {
        for (final kind in (entities.keys.toList()..sort()))
          kind: {for (final id in (entities[kind]!.keys.toList()..sort())) id: verdict(entities[kind]![id]!)},
      },
  };
}

bool _query(SketchRigidity r, RigidityCheck c) => switch (c.query) {
      'fully' => r.isPointFullyConstrained(c.args[0]),
      'over' => r.isPointOverConstrained(c.args[0]),
      'grounded' => r.isPointGrounded(c.args[0]),
      'pinned' => r.isPointPinned(c.args[0]),
      'segment_fully' => r.isSegmentFullyConstrained(c.args[0], c.args[1]),
      'segment_over' => r.isSegmentOverConstrained(c.args[0], c.args[1]),
      'any_grounded' => r.isAnyPointGrounded,
      _ => throw ArgumentError(c.query),
    };

Map<String, dynamic> _build() {
  final cases = <Map<String, dynamic>>[];
  for (final c in rigidityCases()) {
    final r = _run(c.pointIds, c.fixed, c.lines, c.constraints, c.trustConvergedSolve);
    cases.add({
      'id': c.id,
      'description': c.description,
      'input': {
        'point_ids': c.pointIds,
        'fixed': c.fixed.toList()..sort(),
        'lines': {
          for (final id in (c.lines.keys.toList()..sort())) id: [c.lines[id]!.$1, c.lines[id]!.$2]
        },
        'constraints': [for (final k in c.constraints) constraintToWire(k)],
        'trust_converged_solve': c.trustConvergedSolve,
        if (c.entities.isNotEmpty) 'entities': c.entities,
      },
      'checks': [
        for (final k in c.checks) {'query': k.query, 'args': k.args, 'want': k.want},
      ],
      // encodeSketchVectors writes `frames` one per line: the one frame is the expected answer.
      'frames': [
        _expected(r, [...c.pointIds, ...c.fixed], c.entities)
      ],
    });
  }
  return {
    'version': 1,
    'spec': 'docs/sketch-rigidity-spec.md',
    'generator':
        'client/test/sketch_rigidity_vectors_test.dart (tools/sketch_vectors/export_rigidity.sh writes; --check verifies)',
    'dof_cost': dofCostByConstraintType,
    'conventions': {
      'input':
          'point_ids: the sketch\'s points; fixed: the origin and locked points; lines: id -> [start, end]; constraints: '
              'backend wire form (a provisional distance is marked); trust_converged_solve: the backend\'s last solve converged',
      'frames': 'one entry, the expected answer: the sorted ids (of point_ids and fixed) that are fully constrained, '
          'over-constrained, grounded, pinned; any_grounded; entities (scenes): kind -> id -> over | fully | free',
      'checks': 'the assertions dof_analysis_test.dart makes on the same input (query, args, want)',
    },
    'cases': cases,
  };
}

void main() {
  final write = Platform.environment['DIDSA_RIGIDITY_VECTORS'] == 'write';
  final file = File(_path);

  test('the vectors regenerate to the committed file${write ? ' (writing it)' : ''}', () {
    final text = encodeSketchVectors(_build());
    if (write) {
      file.writeAsStringSync(text);
      // ignore: avoid_print
      print('wrote $_path: ${rigidityCases().length} cases');
      return;
    }
    expect(file.existsSync(), isTrue, reason: '$_path is missing: run tools/sketch_vectors/export_rigidity.sh');
    final differences = sketchVectorDifferences(jsonDecode(file.readAsStringSync()), jsonDecode(text), 0);
    expect(differences, isEmpty, reason: differences.take(20).join('\n'));
  });

  group('from the file alone', () {
    if (!file.existsSync()) return;
    final doc = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    for (final c in (doc['cases'] as List).cast<Map<String, dynamic>>()) {
      test(c['id'] as String, () {
        final input = c['input'] as Map<String, dynamic>;
        final lines = {
          for (final e in (input['lines'] as Map<String, dynamic>).entries)
            e.key: (e.value[0] as String, e.value[1] as String),
        };
        final pointIds = (input['point_ids'] as List).cast<String>();
        final fixed = (input['fixed'] as List).cast<String>().toSet();
        final entities = {
          for (final e in ((input['entities'] as Map<String, dynamic>?) ?? const {}).entries)
            e.key: {
              for (final f in (e.value as Map<String, dynamic>).entries) f.key: (f.value as List).cast<String>(),
            },
        };
        final r = _run(
          pointIds,
          fixed,
          lines,
          [for (final w in input['constraints'] as List) ConstraintDto.fromJson(w as Map<String, dynamic>)],
          input['trust_converged_solve'] as bool,
        );
        expect(jsonEncode(_expected(r, [...pointIds, ...fixed], entities)), jsonEncode((c['frames'] as List).single));
        for (final k in c['checks'] as List) {
          final check =
              (query: k['query'] as String, args: (k['args'] as List).cast<String>(), want: k['want'] as bool);
          expect(_query(r, check), check.want, reason: '${c['id']}: ${check.query}${check.args}');
        }
      });
    }
  });
}
