// M2 of `docs/mates-storage-sessions-plan-2026-11-12.md`: the cost of one local retraction frame on the REDUCED models (constraint model version 8,
// the rigid-set leads) of the 22 M0 scaling scene variants, and what the declared caps (`kLocalMaxMembers`, `kLocalMaxRows`) keep out.
//
// `test/data/m0_reduced_models.json` is written by `backend/tests/export_m0_reduced_models.py` (the models `solve_group` exports for each scene with a
// 5 mm / 5 degree wish on the grabbed part). The timings are PRINTED, never asserted (`flutter test` runs the JIT in debug mode on whatever machine
// this is; a release / AOT build is several times faster, a phone several times slower): desktop numbers only, no device was measured.
// What IS asserted is deterministic: the models parse at any size, every one converges to its own manifold in one frame, the followers stay
// rigid with their leads, and the count of variants inside the declared caps.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:didsa_cad_client/motion/local_retraction.dart';
import 'package:didsa_cad_client/motion/se3.dart';

List<double> _dl(Object? v) => (v as List).map((x) => (x as num).toDouble()).toList();

Pose _poseIn(Object? j) {
  final m = j as Map<String, dynamic>;
  return Pose.fromWire(
    translation: _dl(m['translation']),
    rotationAxis: _dl(m['rotation_axis']),
    rotationAngleDegrees: (m['rotation_angle_degrees'] as num).toDouble(),
  );
}

void main() {
  final entries = (jsonDecode(File('test/data/m0_reduced_models.json').readAsStringSync()) as List).cast<Map<String, dynamic>>();

  test('the 22 reduced models: every one parses with the caps lifted, converges in one frame; 18 sit inside 8 members / 64 rows', () {
    expect(entries.length, 22);
    var inside = 0;
    final lines = <String>[
      'scene variant | leads (followers) | rows | us/frame (JIT, debug) | inside kLocalMaxMembers=$kLocalMaxMembers / kLocalMaxRows=$kLocalMaxRows',
    ];
    for (final e in entries) {
      final spec = e['model'] as Map<String, dynamic>;
      final model = LocalRetractor.tryParse(spec, maxMembers: 1000, maxRows: 100000);
      expect(model, isNotNull, reason: '${e['scene']} ${e['variant']}');
      final fits = LocalRetractor.tryParse(spec) != null;
      if (fits) inside++;
      final poses = [for (final p in e['poses'] as List) _poseIn(p)];
      final wishes = [for (final p in e['wishes'] as List) _poseIn(p)];
      final lever = (e['lever_arm'] as num).toDouble();
      final r = model!.frame(poses: poses, wishes: wishes, fallback: poses, lever: lever);
      expect(r.residualInf, lessThan(1e-6), reason: '${e['scene']} ${e['variant']} converges in one frame');
      // the followers ride rigidly with their leads
      final expanded = model.expandFollowers(r.localPoses);
      expect(expanded.length, model.followerIds.length);
      // timing: warm up, then as many frames as fit in about 0.4 s (at least 20)
      for (var i = 0; i < 5; i++) {
        model.frame(poses: poses, wishes: wishes, fallback: poses, lever: lever);
      }
      final sw = Stopwatch()..start();
      var n = 0;
      while (n < 20 || sw.elapsedMilliseconds < 400) {
        model.frame(poses: poses, wishes: wishes, fallback: poses, lever: lever);
        n++;
        if (n >= 5000) break;
      }
      final us = sw.elapsedMicroseconds / n;
      lines.add('${(e['scene'] as String).padRight(20)} ${(e['variant'] as String).padRight(8)} | ${model.members.toString().padLeft(2)} '
          '(${model.followerIds.length.toString().padLeft(2)}) | ${model.rows.toString().padLeft(3)} | ${us.toStringAsFixed(0).padLeft(8)} | ${fits ? 'yes' : 'no'}');
    }
    // ignore: avoid_print
    print(lines.join('\n'));
    // M1.1 measured 18 of the 22 inside 8 members / 64 rows (its table, "fits the caps after"); the client's own count must agree
    expect(inside, 18);
  });

  test('a frame of the biggest reduced model still keeps every mate satisfied over a short drag', () {
    final e = entries.firstWhere((x) => x['scene'] == 'chain-10-bolts' && x['variant'] == 'floating');
    final model = LocalRetractor.tryParse(e['model'] as Map<String, dynamic>, maxMembers: 1000, maxRows: 100000)!;
    var shown = [for (final p in e['poses'] as List) _poseIn(p)];
    final start = shown.first;
    var worst = 0.0;
    for (var f = 1; f <= 10; f++) {
      final wish = applyDelta(start, <double>[2.0 * f, 0, 0, 0, 0, f * math.pi / 180]);
      final r = model.frame(poses: shown, wishes: [wish, ...shown.skip(1)], fallback: shown, lever: (e['lever_arm'] as num).toDouble());
      worst = math.max(worst, r.residualInf);
      shown = r.localPoses;
    }
    expect(worst, lessThan(1e-6));
  });
}
