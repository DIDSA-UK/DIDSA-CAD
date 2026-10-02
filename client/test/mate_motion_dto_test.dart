import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';

/// The contract example (plan §3 / tracker S3), B/C/D scene, grab B, lever_arm 12.5, basis abridged to 2 rows.
/// It still carries the v0 aliases `transform` / `free_twists`, which must be ignored.
const String _convergedJson = '''
{"converged":true,"dof":5,"grounded":true,
 "members":[
  {"occurrence_id":"occ-B","transform":{"translation":[20,20,10],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"mobility":3},
  {"occurrence_id":"occ-C","transform":{"translation":[28,20,10],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"mobility":3},
  {"occurrence_id":"occ-D","transform":{"translation":[20,12,10],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"mobility":3}],
 "basis":[
  [0.5,0,0,0,0,0,0.5,0,0,0,0,0,0,0,0,0,0,0],
  [0,0,0,0,0,0.25,0,0,0,0,0,0.25,0,0,0,0,0,0.25]],
 "chart":{"kind":"se3_owner_frame","lever_arm":12.5},
 "quality":{"residual_inf":1e-15,"sigma_min":0.31,"sigma_gap":40.0,"max_step":null,"jump":0.0},
 "diagnostics":{"solve_ms":3.4},"committed":false,
 "transform":{"translation":[20,20,10],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"free_twists":[]}
''';

const String _notConvergedJson = '''
{"converged":false,"dof":null,"grounded":null,"members":[],"basis":null,
 "quality":{"residual_inf":5.0},"diagnostics":{"solve_ms":1.5},"committed":false}
''';

void main() {
  group('MateMotionDto', () {
    test('converged example: parses every contract field, nullable sigmas/max_step, ignores the v0 aliases', () {
      final d = MateMotionDto.fromJson(jsonDecode(_convergedJson) as Map<String, dynamic>);
      expect(d.converged, isTrue);
      expect(d.dof, 5);
      expect(d.grounded, isTrue);
      expect(d.members.map((m) => m.occurrenceId), ['occ-B', 'occ-C', 'occ-D']);
      expect(d.members.first.mobility, 3);
      expect(d.members[1].transform.translation, [28.0, 20.0, 10.0]);
      expect(d.basis!.length, 2);
      expect(d.basis![1][5], 0.25);
      expect(d.chart!.kind, 'se3_owner_frame');
      expect(d.chart!.leverArm, 12.5);
      expect(d.quality.residualInf, 1e-15);
      expect(d.quality.sigmaMin, 0.31);
      expect(d.quality.sigmaGap, 40.0);
      expect(d.quality.maxStep, isNull);
      expect(d.quality.jump, 0.0);
      expect(d.diagnostics.solveMs, 3.4);
      expect(d.committed, isFalse);
    });

    test('round trip: toJson reproduces the contract fields and emits no alias fields', () {
      final src = jsonDecode(_convergedJson) as Map<String, dynamic>;
      final out = jsonDecode(jsonEncode(MateMotionDto.fromJson(src).toJson())) as Map<String, dynamic>;
      expect(out.containsKey('transform'), isFalse);
      expect(out.containsKey('free_twists'), isFalse);
      final expected = Map<String, dynamic>.of(src)
        ..remove('transform')
        ..remove('free_twists');
      expect(out, expected);
      // and it parses back to the same thing
      expect(jsonEncode(MateMotionDto.fromJson(out).toJson()), jsonEncode(out));
    });

    test('converged:false carries no basis / dof / members / chart and is never read as "all free"', () {
      final src = jsonDecode(_notConvergedJson) as Map<String, dynamic>;
      final d = MateMotionDto.fromJson(src);
      expect(d.converged, isFalse);
      expect(d.dof, isNull);
      expect(d.grounded, isNull);
      expect(d.members, isEmpty);
      expect(d.basis, isNull);
      expect(d.chart, isNull);
      expect(d.quality.residualInf, 5.0);
      expect(d.quality.sigmaGap, isNull);
      expect(d.quality.jump, isNull);
      expect(projectorFromMateMotion(d), isNull);
      final out = jsonDecode(jsonEncode(d.toJson())) as Map<String, dynamic>;
      expect(out['converged'], false);
      expect(out['basis'], isNull);
      expect(out['members'], isEmpty);
    });

    test('rank 0: null sigmas parse', () {
      final d = MateMotionDto.fromJson(jsonDecode(
        '{"converged":true,"dof":0,"grounded":true,"members":[{"occurrence_id":"a","transform":{"translation":[0,0,0],"rotation_axis":[0,0,1],"rotation_angle_degrees":0},"mobility":0}],'
        '"basis":[],"chart":{"kind":"se3_owner_frame","lever_arm":10},"quality":{"residual_inf":0,"sigma_min":null,"sigma_gap":null,"max_step":null,"jump":0},'
        '"diagnostics":{"solve_ms":0.1},"committed":false}',
      ) as Map<String, dynamic>);
      expect(d.quality.sigmaMin, isNull);
      expect(d.quality.sigmaGap, isNull);
      final p = projectorFromMateMotion(d)!;
      expect(p.dim, 0);
    });

    test('bridge builds a projector from the converged example', () {
      final p = projectorFromMateMotion(MateMotionDto.fromJson(jsonDecode(_convergedJson) as Map<String, dynamic>))!;
      expect(p.members, 3);
      expect(p.lever, 12.5);
      expect(p.dim, 2);
    });

    test('bridge rejects a basis whose width is not 6*members', () {
      final src = jsonDecode(_convergedJson) as Map<String, dynamic>;
      (src['basis'] as List)[0] = [1.0, 0.0];
      expect(projectorFromMateMotion(MateMotionDto.fromJson(src)), isNull);
    });
  });

  group('MateMotionRequestDto / DocumentApiClient.mateMotion', () {
    test('request JSON: reference poses are sent only when given', () {
      final withRef = MateMotionRequestDto(
        reference: [
          MateMotionMemberDto(
            occurrenceId: 'occ-B',
            transform: RigidTransformDto(translation: const [1, 2, 3], rotationAxis: const [0, 0, 1], rotationAngleDegrees: 0),
            mobility: 3,
          ),
        ],
      ).toJson();
      expect(withRef['reference'], [
        {
          'occurrence_id': 'occ-B',
          'transform': {'translation': [1, 2, 3], 'rotation_axis': [0, 0, 1], 'rotation_angle_degrees': 0},
        }
      ]);
      expect(const MateMotionRequestDto().toJson().containsKey('reference'), isFalse);
      expect(const MateMotionRequestDto().toJson().containsKey('include_constraint_model'), isFalse);
      expect(const MateMotionRequestDto(includeConstraintModel: false).toJson()['include_constraint_model'], isFalse);
    });

    test('request JSON: null transform is sent as null, lever_arm only when given', () {
      expect(const MateMotionRequestDto().toJson(), {'transform': null, 'commit': false});
      final j = MateMotionRequestDto(
        transform: RigidTransformDto(translation: [1, 2, 3], rotationAxis: [0, 0, 1], rotationAngleDegrees: 30),
        leverArm: 41.2,
        commit: true,
      ).toJson();
      expect(j['lever_arm'], 41.2);
      expect(j['commit'], true);
      expect((j['transform'] as Map)['rotation_angle_degrees'], 30);
    });

    test('mateMotion posts to the grabbed occurrence and parses the response', () async {
      late http.Request seen;
      final api = DocumentApiClient(
        httpClient: MockClient((req) async {
          seen = req;
          return http.Response(_convergedJson, 200, headers: {'content-type': 'application/json'});
        }),
      );
      final r = await api.mateMotion('part-1', 'occ-B', leverArm: 12.5, commit: true);
      expect(seen.method, 'POST');
      expect(seen.url.path, '/document/parts/part-1/occurrences/occ-B/mate-motion');
      final body = jsonDecode(seen.body) as Map<String, dynamic>;
      expect(body['transform'], isNull);
      expect(body['lever_arm'], 12.5);
      expect(body['commit'], true);
      expect(r.dof, 5);
      expect(r.members.length, 3);
    });
  });
}
