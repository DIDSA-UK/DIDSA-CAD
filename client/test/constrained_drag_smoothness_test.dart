// SMOOTHNESS STUDY of the constrained drag on multi-part assemblies with variable degrees of freedom, against the REAL
// backend (OCCT + py-slvs). Env-gated like `constrained_drag_live_test.dart` (skipped in CI): `DIDSA_SMOOTH_MANIFEST` is
// the manifest written by `tools/motion_smoothness/serve_scene.py` (scene + variant), `DIDSA_SMOOTH_PATHS` a comma list
// of hand paths (default: all), `DIDSA_SMOOTH_OUT` a JSONL file the rows are appended to.
//
// For every path a simulated hand (minimum-jerk profile, 60 Hz, real clock) drags the scene's `mover` occurrence through
// a [ConstrainedDragSession]. Per frame it records the shown pose of EVERY member, and compares it with the exact
// answer to the same wish (a fresh `mate-motion` solve per frame = the ground truth the display is trying to match):
//   * step ratio  = shown per-frame step / hand per-frame step      (1 = the part moves as smoothly as the hand)
//   * jerk        = |step_i - step_(i-1)|                           (pops show up here)
//   * track error = distance of the shown pose from the exact answer
// distances are in the projection metric `[1,1,1,L,L,L]` (weighted mm). Nothing is committed: every path starts from the
// same scene state.
@TestOn('vm')
library;

import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/motion/constrained_drag_session.dart';
import 'package:didsa_cad_client/motion/mate_motion_bridge.dart';
import 'package:didsa_cad_client/motion/se3.dart';

class _LiveClient extends http.BaseClient {
  _LiveClient(this.base, this.key);
  final Uri base;
  final String key;
  final http.Client _inner = http.Client();

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    final req = http.Request(request.method, base.resolveUri(request.url));
    req.headers.addAll(request.headers);
    req.headers['X-API-Key'] = key;
    req.headers.remove('X-Document-Session');
    if (request is http.Request) req.bodyBytes = request.bodyBytes;
    return _inner.send(req);
  }
}

double _minJerk(double t) => 10 * t * t * t - 15 * t * t * t * t + 6 * t * t * t * t * t;

/// The hand: wished pose of the grabbed occurrence at progress [t] in 0..1 for path [name], from [base].
Pose _hand(String name, Pose base, double t) {
  final s = _minJerk(t);
  const deg = math.pi / 180;
  Pose rot(double ax, double ay, double az, double deg_) =>
      applyDelta(base, <double>[0, 0, 0, ax * deg_ * deg * s, ay * deg_ * deg * s, az * deg_ * deg * s]);
  switch (name) {
    case 'rot_x_120':
      return rot(1, 0, 0, 120);
    case 'rot_y_120':
      return rot(0, 1, 0, 120);
    case 'rot_z_120':
      return rot(0, 0, 1, 120);
    case 'rot_xy_60':
      return rot(0.7071, 0.7071, 0, 60);
    case 'trans_x_40':
      return applyDelta(base, <double>[40 * s, 0, 0, 0, 0, 0]);
    case 'trans_z_40':
      return applyDelta(base, <double>[0, 0, 40 * s, 0, 0, 0]);
    case 'radial_out_back_12': // pull out sideways and return: blocked by most mates
      return applyDelta(base, <double>[12 * math.sin(math.pi * t), 0, 0, 0, 0, 0]);
    case 'circle_xy_25': // a circle in the xy plane: continuously turning direction, mostly off-manifold
      return applyDelta(base, <double>[25 * (math.cos(2 * math.pi * s) - 1), 25 * math.sin(2 * math.pi * s), 0, 0, 0, 0]);
    case 'rot_x_fast_180': // a flick: 180 deg in a third of the time
      final f = _minJerk(math.min(1.0, t * 3));
      return applyDelta(base, <double>[0, 0, 0, math.pi * f, 0, 0]);
    default:
      throw ArgumentError(name);
  }
}

const _allPaths = <String>[
  'rot_x_120', 'rot_y_120', 'rot_z_120', 'rot_xy_60', 'trans_x_40', 'trans_z_40', 'radial_out_back_12', 'circle_xy_25', 'rot_x_fast_180',
];

double _pct(List<double> v, double p) {
  if (v.isEmpty) return 0;
  final s = List<double>.of(v)..sort();
  return s[((s.length - 1) * p).round()];
}

void main() {
  final manifestPath = Platform.environment['DIDSA_SMOOTH_MANIFEST'];
  final paths = (Platform.environment['DIDSA_SMOOTH_PATHS'] ?? _allPaths.join(',')).split(',');
  final outPath = Platform.environment['DIDSA_SMOOTH_OUT'];

  for (final path in paths) {
    test('smoothness: $path', () async {
      final m = jsonDecode(File(manifestPath!).readAsStringSync()) as Map<String, dynamic>;
      final root = m['root'] as String;
      final mover = (m['roles'] as Map<String, dynamic>)['mover'] as String;
      final api = DocumentApiClient(httpClient: _LiveClient(Uri.parse('http://127.0.0.1:8000'), m['key'] as String));
      final clock = Stopwatch()..start();
      final session = ConstrainedDragSession(
        call: api.mateMotion,
        partId: root,
        grabbedId: mover,
        leverArm: 10.0,
        nowMs: () => clock.elapsedMicroseconds / 1000.0,
        useReference: (Platform.environment['DIDSA_SMOOTH_REFERENCE'] ?? '').isNotEmpty,
        useLocalRetraction: (Platform.environment['DIDSA_SMOOTH_LOCAL'] ?? '1') != '0', // F1b: DIDSA_SMOOTH_LOCAL=0 = projector only
      );
      await session.begin();
      expect(session.hasModel, isTrue, reason: 'grab anchor: ${session.counters.toJson()}');
      final ids = session.memberIds;
      final lever = session.anchor!.chart!.leverArm;
      final base = poseOfDto(session.anchor!.members.first.transform);
      final dof = session.anchor!.dof, grounded = session.anchor!.grounded;

      const frames = 90;
      List<Pose>? prevShown;
      Pose? prevHand;
      final handStep = <double>[], stepG = <double>[], stepF = <double>[], errG = <double>[], errF = <double>[], truthStepG = <double>[];
      List<Pose>? prevTruth;
      for (var f = 1; f <= frames; f++) {
        final wish = _hand(path, base, f / frames);
        final frame = session.update(wish);
        // ground truth: the exact answer to the same wish, solved from the stored pose
        final truthDto = await api.mateMotion(root, mover, transform: dtoOfPose(wish), leverArm: lever);
        final truth = <Pose>[
          for (final id in ids)
            if (truthDto.converged) poseOfDto(truthDto.members.firstWhere((x) => x.occurrenceId == id).transform) else base
        ];
        if (frame != null) {
          final shown = frame.poses;
          if (prevShown != null) {
            handStep.add(weightedDist(wish, prevHand!, lever));
            stepG.add(weightedDist(shown[0], prevShown[0], lever));
            var followerMax = 0.0;
            for (var i = 1; i < shown.length; i++) {
              followerMax = math.max(followerMax, weightedDist(shown[i], prevShown[i], lever));
            }
            stepF.add(followerMax);
            if (prevTruth != null) truthStepG.add(weightedDist(truth[0], prevTruth[0], lever));
          }
          errG.add(weightedDist(shown[0], truth[0], lever));
          var fe = 0.0;
          for (var i = 1; i < shown.length; i++) {
            fe = math.max(fe, weightedDist(shown[i], truth[i], lever));
          }
          errF.add(fe);
          prevShown = shown;
        }
        prevHand = wish;
        prevTruth = truth;
        await Future<void>.delayed(const Duration(milliseconds: 16));
      }
      final jerk = <double>[for (var i = 1; i < stepG.length; i++) (stepG[i] - stepG[i - 1]).abs()];
      final jerkF = <double>[for (var i = 1; i < stepF.length; i++) (stepF[i] - stepF[i - 1]).abs()];
      final handMax = handStep.isEmpty ? 0.0 : handStep.reduce(math.max);
      final handJerk = <double>[for (var i = 1; i < handStep.length; i++) (handStep[i] - handStep[i - 1]).abs()];
      double ratioMax(List<double> shown) {
        var r = 0.0;
        for (var i = 0; i < shown.length; i++) {
          if (handStep[i] > 0.2 * handMax) r = math.max(r, shown[i] / handStep[i]);
        }
        return r;
      }

      final c = session.counters;
      final row = <String, Object?>{
        'scene': m['scene'], 'variant': m['variant'], 'ref': session.useReference, 'local': session.useLocalRetraction, 'local_accepted': session.counters.localAccepted, 'local_fallbacks': session.counters.localFallbacks, 'path': path, 'members': ids.length, 'dof': dof, 'grounded': grounded,
        'requests': c.requests, 'rejected': c.anchorsRejectedTotal, 'holds': c.holds,
        'hand_step_max': double.parse(handMax.toStringAsFixed(3)),
        'step_g_max': double.parse((stepG.isEmpty ? 0.0 : stepG.reduce(math.max)).toStringAsFixed(3)),
        'step_ratio_g_max': double.parse(ratioMax(stepG).toStringAsFixed(2)),
        'step_f_max': double.parse((stepF.isEmpty ? 0.0 : stepF.reduce(math.max)).toStringAsFixed(3)),
        'truth_step_g_max': double.parse((truthStepG.isEmpty ? 0.0 : truthStepG.reduce(math.max)).toStringAsFixed(3)),
        'jerk_g_max': double.parse((jerk.isEmpty ? 0.0 : jerk.reduce(math.max)).toStringAsFixed(3)),
        'jerk_f_max': double.parse((jerkF.isEmpty ? 0.0 : jerkF.reduce(math.max)).toStringAsFixed(3)),
        'hand_jerk_max': double.parse((handJerk.isEmpty ? 0.0 : handJerk.reduce(math.max)).toStringAsFixed(3)),
        'err_g_p95': double.parse(_pct(errG, 0.95).toStringAsFixed(3)),
        'err_g_max': double.parse((errG.isEmpty ? 0.0 : errG.reduce(math.max)).toStringAsFixed(3)),
        'err_f_max': double.parse((errF.isEmpty ? 0.0 : errF.reduce(math.max)).toStringAsFixed(3)),
      };
      // ignore: avoid_print
      print('SMOOTH ${jsonEncode(row)}');
      if (outPath != null) File(outPath).writeAsStringSync('${jsonEncode(row)}\n', mode: FileMode.append);
    }, skip: manifestPath == null ? 'set DIDSA_SMOOTH_MANIFEST (see the file header)' : false, timeout: const Timeout(Duration(minutes: 5)));
  }
}
