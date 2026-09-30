// S8: per-handle freedom, screw-axis pivots and the plane handle, computed from the free-motion bases of the golden
// vector scenes (`docs/motion/vectors.json`, read from the repo root like the golden-vector test does): face,
// off-axis concentric, angle cone and the B/C/D group.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/motion/free_motion_projector.dart';
import 'package:didsa_cad_client/motion/gizmo_freedom.dart';
import 'package:didsa_cad_client/motion/se3.dart';

List<double> _dl(Object? v) => (v as List).map((x) => (x as num).toDouble()).toList();

GizmoFreedom _scene(String id, {int? dof, bool? grounded, int? mobility}) {
  final doc = jsonDecode(File('../docs/motion/vectors.json').readAsStringSync()) as Map<String, dynamic>;
  final c = (doc['cases'] as List).cast<Map<String, dynamic>>().firstWhere((c) => c['id'] == id);
  final i = c['input'] as Map<String, dynamic>;
  final model = FreeMotionProjector.fromAnchor(
    refs: [
      for (final r in i['refs'] as List)
        Pose.fromWire(
          translation: _dl((r as Map)['translation']),
          rotationAxis: _dl(r['rotation_axis']),
          rotationAngleDegrees: (r['rotation_angle_degrees'] as num).toDouble(),
        ),
    ],
    basis: [for (final row in i['basis'] as List) _dl(row)],
    lever: (i['lever_arm'] as num).toDouble(),
    followerWeight: (i['follower_weight'] as num).toDouble(),
  );
  return gizmoFreedomFromModel(model, dof: dof, grounded: grounded, mobility: mobility);
}

List<double> _fr(List<HandleFreedom> h) => [for (final x in h) double.parse(x.fraction.toStringAsFixed(3))];

void main() {
  test('face mate (in-plane slide + spin about the normal, part turned 30 deg): x/y free, z and tilts locked, plane handle', () {
    final f = _scene('flat-inplane', dof: 3, grounded: true, mobility: 3);
    expect(_fr(f.translate), [1.0, 1.0, 0.0]);
    expect(_fr(f.rotate), [0.0, 0.0, 1.0]);
    expect(f.translate[2].locked, isTrue);
    expect(f.rotate[2].free, isTrue);
    expect(f.rotate[2].pivot, isNull, reason: 'spin about the occurrence origin: the ring is already right');
    expect(f.planeNormal, isNotNull);
    expect(f.planeNormal![2].abs(), closeTo(1, 1e-9), reason: 'the plane normal is the face normal (world z)');
    expect(f.immobile, isFalse);
    expect(f.summary, 'Group: 3 DOF');
  });

  test('off-axis concentric pin: the z ring re-pivots onto the pin axis and reads free; x/y translations locked, z partial', () {
    final f = _scene('conc-spin-90', dof: 2, grounded: true, mobility: 2);
    final z = f.rotate[2];
    expect(z.free, isTrue);
    expect(z.pivot, isNotNull);
    expect(z.pivot![0], closeTo(0, 1e-9));
    expect(z.pivot![1], closeTo(0, 1e-9));
    expect(z.pivot![2], closeTo(30, 1e-9), reason: 'the pin axis is the world z axis, pivot at the part\'s height');
    expect(z.pivotAxis, [0.0, 0.0, 1.0].map((v) => closeTo(v, 1e-9)).toList());
    expect(f.translate[2].free, isTrue, reason: 'slide along the pin axis');
    expect(f.translate[0].locked, isTrue, reason: 'radial x is blocked');
    expect(f.translate[1].partial, isTrue, reason: 'y only moves together with the swing');
    expect(f.rotate[0].locked && f.rotate[1].locked, isTrue, reason: 'tilts are blocked');
    expect(f.planeNormal, isNull, reason: 'only one pure translation is free: no plane handle');
  });

  test('angle cone: spin about the cone axis and about the locked-perpendicular axis are free, the normal-changing tilt is locked', () {
    final f = _scene('angle-tilt-off-cone', dof: 5, grounded: true, mobility: 5);
    expect(_fr(f.translate), [1.0, 1.0, 1.0]);
    expect(f.rotate[2].free, isTrue, reason: 'local z = the cone axis');
    expect(f.rotate[2].pivot, isNull);
    expect(f.rotate[1].locked, isTrue, reason: 'rotation about world y changes the cone angle');
    expect(f.rotate[0].free, isTrue);
    expect(f.planeNormal, isNull, reason: 'all three translations are free');
  });

  test('B/C/D group grabbing B: x/y drag the group (followers follow), z locked, plane handle; group dof 5', () {
    final f = _scene('bcd-B-plus-6y', dof: 5, grounded: true, mobility: 3);
    expect(f.translate[0].free && f.translate[1].free, isTrue);
    expect(f.translate[2].locked, isTrue);
    expect(f.planeNormal, isNotNull);
    expect(f.planeNormal![2].abs(), closeTo(1, 1e-6));
    expect(f.summary, 'Group: 5 DOF');
  });

  test('fully constrained / locked / not grounded: immobile flag, reason and summary', () {
    final a = _scene('flat-inplane', dof: 0, grounded: true, mobility: 0);
    expect(a.immobile, isTrue);
    expect(a.reason, contains('Fully constrained'));
    expect(a.summary, 'Fully constrained (0 DOF)');
    final b = _scene('flat-inplane', dof: 3, grounded: true, mobility: 0);
    expect(b.immobile, isTrue);
    expect(b.reason, contains('lock'));
    final c = _scene('flat-inplane', dof: 6, grounded: false, mobility: 6);
    expect(c.immobile, isFalse);
    expect(c.summary, 'Group: 6 DOF - not grounded');
  });

  test('gizmoFreedomFromAnchor: converged:false carries no model (null), a rank-0 answer is immobile', () {
    expect(gizmoFreedomFromAnchor(const MateMotionDto(converged: false)), isNull);
    final rank0 = MateMotionDto(
      converged: true,
      dof: 0,
      grounded: true,
      members: [
        MateMotionMemberDto(
          occurrenceId: 'B',
          transform: RigidTransformDto(translation: [0, 0, 0], rotationAxis: [0, 0, 1], rotationAngleDegrees: 0),
          mobility: 0,
        ),
      ],
      basis: const [],
      chart: const MateMotionChartDto(kind: 'se3_owner_frame', leverArm: 10),
    );
    final f = gizmoFreedomFromAnchor(rank0)!;
    expect(f.immobile, isTrue);
    expect(_fr(f.translate), [0.0, 0.0, 0.0]);
    expect(f.planeNormal, isNull);
  });
}
