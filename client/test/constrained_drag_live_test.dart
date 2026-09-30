// LIVE check of the constrained-drag session against a REAL backend (OCCT + py-slvs). Skipped unless
// `DIDSA_LIVE_MANIFEST` names a JSON manifest written by a script that built one scene and serves the backend on
// 127.0.0.1:8000:  {"root": <part id>, "grabbed": <occurrence id>, "key": <api key>}
// `DIDSA_LIVE_PATH` = comma-separated simulated hand paths. The flat app's gizmo handle is single-axis, so the
// realistic ones are flat_x | flat_spin | swing_z | angle_x | angle_y | angle_z; flat_combined | swing_slide_turn mix a slide with a turn
// (not reachable from one handle; kept because they expose the additive-chart `max_step`, plan F2).
//
// Not part of the normal suite (no backend in CI). It prints the drag's counters - the F1-gate numbers
// (`docs/constrained-drag-implementation-plan.md` §5) - and asserts that the stored poses satisfy the mates.
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
    req.headers.remove('X-Document-Session'); // the scene lives in the backend's default document session
    if (request is http.Request) req.bodyBytes = request.bodyBytes;
    return _inner.send(req);
  }
}

void main() {
  final manifestPath = Platform.environment['DIDSA_LIVE_MANIFEST'];
  final paths = (Platform.environment['DIDSA_LIVE_PATH'] ?? 'flat_x').split(',');

  for (final path in paths) {
  test('live drag ($path): request budget, mate satisfied after commit', () async {
    final m = jsonDecode(File(manifestPath!).readAsStringSync()) as Map<String, dynamic>;
    final root = m['root'] as String, grabbed = m['grabbed'] as String;
    final api = DocumentApiClient(httpClient: _LiveClient(Uri.parse('http://127.0.0.1:8000'), m['key'] as String));
    // A scene built by a script may start with the mate unsatisfied (the app snaps it when the mate is created): snap it.
    await api.mateMotion(root, grabbed, commit: true);
    final clock = Stopwatch()..start();

    final session = ConstrainedDragSession(
      call: api.mateMotion,
      partId: root,
      grabbedId: grabbed,
      leverArm: 10.0,
      nowMs: () => clock.elapsedMicroseconds / 1000.0,
    );
    await session.begin();
    expect(session.hasModel, isTrue, reason: 'the grab anchor was accepted: ${session.counters.toJson()}');
    final base = poseOfDto(session.anchor!.members.first.transform);
    final L = session.anchor!.chart!.leverArm;
    // ignore: avoid_print
    print('live[$path] grab anchor: dof=${session.anchor!.dof} grounded=${session.anchor!.grounded} '
        'members=${session.memberIds} lever=$L');

    const frames = 60;
    Pose wishAt(int f) {
      final s = f / frames;
      switch (path) {
        case 'swing_z': // rotate handle about the occurrence's own z axis (through its origin, 15 mm off the pin axis)
          return applyDelta(base, <double>[0, 0, 0, 0, 0, math.pi / 2 * s]);
        case 'swing_slide_turn': // the prototype's swing: slide 15 along the pin's axis while turning 90 deg
          return applyDelta(base, <double>[0, 0, 15.0 * s, 0, 0, math.pi / 2 * s]);
        case 'angle_x': // rotate handle about x, 40 deg
          return applyDelta(base, <double>[0, 0, 0, 40.0 * math.pi / 180 * s, 0, 0]);
        case 'angle_z': // spin about the cone's axis (free)
          return applyDelta(base, <double>[0, 0, 0, 0, 0, math.pi / 2 * s]);
        case 'angle_y': // tilt about y (partly off the cone: the curved case)
          return applyDelta(base, <double>[0, 0, 0, 0, 40.0 * math.pi / 180 * s, 0]);
        case 'flat_spin': // rotate handle about z, 35 deg
          return applyDelta(base, <double>[0, 0, 0, 0, 0, 35.0 * math.pi / 180 * s]);
        case 'flat_combined': // slide + spin + pull off the plane
          return applyDelta(base, <double>[30.0 * s, 20.0 * s, 6.0 * s, 0, 0, 0.6 * s]);
        default: // flat_x: translate handle along x (30 mm)
          return applyDelta(base, <double>[30.0 * s, 0, 0, 0, 0, 0]);
      }
    }

    var handMax = 0.0;
    Pose? prevHand;
    for (var f = 1; f <= frames; f++) {
      final w = wishAt(f);
      if (prevHand != null) handMax = math.max(handMax, weightedDist(w, prevHand, L));
      prevHand = w;
      final fr = session.update(w);
      if ((Platform.environment['DIDSA_LIVE_DEBUG'] ?? '').isNotEmpty && f % 15 == 0 && fr != null) {
        // ignore: avoid_print
        print('  frame $f wish t=${w.t.map((v) => v.toStringAsFixed(2))} shown t=${fr.poses[0].t.map((v) => v.toStringAsFixed(2))} '
            'rotvec=${rotvecFromRot(fr.poses[0].r).map((v) => v.toStringAsFixed(3))}');
      }
      await Future<void>.delayed(const Duration(milliseconds: 16));
    }
    final commit = await session.finish(wish: wishAt(frames));
    expect(commit.committed, isTrue, reason: commit.message);
    // ignore: avoid_print
    print('live[$path] ${session.counters.logLine()} | hand max step=${handMax.toStringAsFixed(3)} | '
        'final dof=${commit.response!.dof}');

    // The stored poses satisfy the mates: a fresh anchor at the stored pose is a fixed point (no solve movement).
    final again = await api.mateMotion(root, grabbed, transform: null, leverArm: L);
    expect(again.converged, isTrue);
    expect(again.quality.residualInf!, lessThan(1e-7));
    for (final mem in commit.response!.members) {
      final a = poseOfDto(mem.transform);
      final b = poseOfDto(again.members.firstWhere((x) => x.occurrenceId == mem.occurrenceId).transform);
      expect(weightedDist(a, b, L), lessThan(1e-6), reason: '${mem.occurrenceId} moved when re-solved from its stored pose');
    }
    if (!path.contains('combined') && !path.contains('slide_turn')) {
      expect(session.counters.requests, lessThanOrEqualTo(1 + (frames * 16 ~/ 150) + 3 + 1));
    }
  }, skip: manifestPath == null ? 'set DIDSA_LIVE_MANIFEST (see the file header)' : false, timeout: const Timeout(Duration(minutes: 3)));
  }
}
