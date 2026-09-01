import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/part_screen.dart';
import 'package:didsa_cad_client/viewport3d/part_viewport.dart';
import 'package:didsa_cad_client/viewport3d/pending_job_store.dart';

/// LOD Phase 2 chunk 4 (`docs/lod-strategy/02-phase2-design.md` SS6 item 4):
/// [PartScreen]'s own job-mode tracking - pending -> coarse shown -> polling
/// -> succeeded/failed/cancelled/unknown -> UI state cleared. A job-mode
/// create ([BevelDesignScreen]/[GearChainDesignScreen], covered by their own
/// test files) and a genuine resume-on-reconnect both funnel into the exact
/// same [PendingJobStore]-driven path (`PartScreen._checkForPendingJob`), so
/// these tests exercise it directly by seeding [PendingJobStore] and
/// constructing [PartScreen] with `initialPartId` - the same thing a real
/// relaunch re-opening that Part id would do.
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  const placeholderMesh = {
    'vertices': [
      [0.0, 0.0, 0.0],
      [1.0, 0.0, 0.0],
      [0.0, 1.0, 0.0],
    ],
    'normals': [
      [0.0, 0.0, 1.0],
      [0.0, 0.0, 1.0],
      [0.0, 0.0, 1.0],
    ],
    'triangle_indices': [
      [0, 1, 2],
    ],
    'face_ids': [0],
  };

  Map<String, dynamic> bevelPairPayload() => DocumentApiClient.bevelPairFeatureJson(
        module: 4.0,
        toothCount1: 20,
        toothCount2: 40,
        faceWidth: 15.0,
        spiralAngleDegrees: 25.0,
      );

  Map<String, dynamic> bevelPairFeatureResponseJson() => {
        'type': 'bevel_pair',
        'id': 'pair-1',
        'locked': false,
        'produces': 'body',
        'module': 4.0,
        'member_1': {'tooth_count': 20, 'profile_shift': null},
        'member_2': {'tooth_count': 40, 'profile_shift': null},
        'face_width': 15.0,
        'pressure_angle_degrees': 20.0,
        'shaft_angle_degrees': 90.0,
        'backlash': 0.0,
      };

  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Future<void> seedPendingJob({required String jobId}) => PendingJobStore.save(PendingFeatureJob(
        partId: 'part-1',
        jobId: jobId,
        featureKind: PendingFeatureJob.kindBevelPair,
        coarsePreviewPayload: bevelPairPayload(),
      ));

  /// A handful of short pumps let every already-resolved Future's
  /// microtasks/`setState`s flush without advancing the fake clock far
  /// enough to trigger [_PartScreenState._jobPollTimer]'s own next tick -
  /// `pumpAndSettle` can't be used anywhere a job is still `running`, since
  /// its `Timer.periodic` never naturally settles.
  Future<void> pumpSettleWithoutTicking(WidgetTester tester) async {
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  testWidgets('resumes a pending job on load: shows the coarse placeholder and Cancel while running', (
    tester,
  ) async {
    await seedPendingJob(jobId: 'job-1');
    var jobStatusCalls = 0;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
            {'body_id': 'coarse-member-2', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-1' && request.method == 'GET') {
          jobStatusCalls++;
          return jsonResponse({'job_id': 'job-1', 'status': 'running'});
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);

    expect(jobStatusCalls, greaterThanOrEqualTo(1));
    expect(find.text('Cancel'), findsOneWidget);
    expect(find.text('Building geometry - complex gears can take a while...'), findsOneWidget);
    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    expect(viewport.transientCoarsePreviewBodies.map((b) => b.bodyId).toList(),
        ['coarse-member-1', 'coarse-member-2']);

    // Advancing past the poll interval must fire another status check -
    // proves this is genuinely polling, not a one-shot check.
    final callsAfterFirstSettle = jobStatusCalls;
    await tester.pump(const Duration(seconds: 2));
    await pumpSettleWithoutTicking(tester);
    expect(jobStatusCalls, greaterThan(callsAfterFirstSettle));
    expect(find.text('Cancel'), findsOneWidget);

    // Unmount so `PartScreen.dispose` cancels the still-running poll Timer -
    // otherwise the test framework flags it as a leaked pending Timer.
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('succeeded: swaps in the real result, clears the job/coarse state and PendingJobStore', (
    tester,
  ) async {
    await seedPendingJob(jobId: 'job-2');
    var jobStatusCalls = 0;
    var featuresCalls = 0;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          featuresCalls++;
          if (featuresCalls == 1) return jsonResponse([]);
          return jsonResponse([bevelPairFeatureResponseJson()]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-2' && request.method == 'GET') {
          jobStatusCalls++;
          if (jobStatusCalls == 1) return jsonResponse({'job_id': 'job-2', 'status': 'running'});
          return jsonResponse({'job_id': 'job-2', 'status': 'succeeded', 'result': bevelPairFeatureResponseJson()});
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);
    expect(jobStatusCalls, 1);
    expect(find.text('Cancel'), findsOneWidget);

    // The next poll tick sees 'succeeded'.
    await tester.pump(const Duration(seconds: 2));
    await pumpSettleWithoutTicking(tester);

    expect(jobStatusCalls, greaterThanOrEqualTo(2));
    expect(find.text('Cancel'), findsNothing);
    expect(find.text('Building geometry - complex gears can take a while...'), findsNothing);
    expect(featuresCalls, greaterThanOrEqualTo(2), reason: 'the real result must be fetched via a plain refresh');
    expect(await PendingJobStore.load(), isNull);
    final viewport = tester.widget<PartViewport>(find.byType(PartViewport));
    expect(viewport.transientCoarsePreviewBodies, isEmpty);
  });

  testWidgets('failed: surfaces the structured error and clears the job/coarse state', (tester) async {
    await seedPendingJob(jobId: 'job-3');
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-3' && request.method == 'GET') {
          return jsonResponse({
            'job_id': 'job-3',
            'status': 'failed',
            'error': {'type': 'bevel_failed', 'detail': 'unresolvable spiral bevel pair'},
          });
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);

    expect(find.text('Cancel'), findsNothing);
    expect(find.textContaining('unresolvable spiral bevel pair'), findsOneWidget);
    expect(await PendingJobStore.load(), isNull);
  });

  testWidgets('cancelled (e.g. by another client mid-resume): clears the job/coarse state with no error', (
    tester,
  ) async {
    await seedPendingJob(jobId: 'job-4');
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-4' && request.method == 'GET') {
          return jsonResponse({'job_id': 'job-4', 'status': 'cancelled'});
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);

    expect(find.text('Cancel'), findsNothing);
    expect(find.textContaining('Build failed'), findsNothing);
    expect(await PendingJobStore.load(), isNull);
  });

  testWidgets('tapping Cancel calls the cancel endpoint and clears state without waiting for the next poll', (
    tester,
  ) async {
    await seedPendingJob(jobId: 'job-5');
    var cancelCalls = 0;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-5/cancel' && request.method == 'POST') {
          cancelCalls++;
          return jsonResponse({'job_id': 'job-5', 'status': 'running'});
        }
        if (path == '/document/parts/part-1/jobs/job-5' && request.method == 'GET') {
          return jsonResponse({'job_id': 'job-5', 'status': 'running'});
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);
    expect(find.text('Cancel'), findsOneWidget);

    await tester.tap(find.text('Cancel'));
    await pumpSettleWithoutTicking(tester);

    expect(cancelCalls, 1);
    expect(find.text('Cancel'), findsNothing);
    expect(await PendingJobStore.load(), isNull);
  });

  testWidgets('unknown job (404, e.g. a server restart wiped the in-memory job store): stops tracking instead '
      'of polling forever', (tester) async {
    await seedPendingJob(jobId: 'job-6');
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        if (path == '/document/parts/part-1/bevel-pair-features/coarse-preview' && request.method == 'POST') {
          return jsonResponse([
            {'body_id': 'coarse-member-1', 'source': 'coarse', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/jobs/job-6' && request.method == 'GET') {
          return jsonResponse({'detail': 'job not found'}, status: 404);
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);

    expect(find.text('Cancel'), findsNothing);
    expect(find.textContaining('Lost track of the in-progress build'), findsOneWidget);
    expect(await PendingJobStore.load(), isNull);
  });

  testWidgets('a Part with no pending job never shows the job-mode Cancel affordance', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final path = request.url.path;
        if (path == '/document/parts/part-1' && request.method == 'GET') {
          return jsonResponse({'id': 'part-1', 'name': 'Part 1', 'feature_ids': []});
        }
        if (path == '/document/parts/part-1/mesh' && request.method == 'GET') {
          return jsonResponse([
            {'body_id': 'placeholder', 'source': 'placeholder', 'mesh': placeholderMesh},
          ]);
        }
        if (path == '/document/parts/part-1/features' && request.method == 'GET') {
          return jsonResponse([]);
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: PartScreen(documentApi: client, initialPartId: 'part-1')));
    await pumpSettleWithoutTicking(tester);

    expect(find.text('Cancel'), findsNothing);
  });
}
