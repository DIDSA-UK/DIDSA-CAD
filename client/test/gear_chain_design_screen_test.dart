import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/gear/gear_chain_design_screen.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`'s "Chain/planetary/
/// bevel-pair preview" extension - widget-level coverage for
/// [GearChainDesignScreen], mirroring `gear_design_screen_test.dart`'s own
/// shape: a fake [MockClient] stands in for the real backend, no real
/// network, no OCCT dependency in this screen's own import chain.
void main() {
  // GearChainDesignScreen now warms GearPresetStore's cache in initState -
  // see gear_design_screen_test.dart's own identical setUp for why.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> member({
    required int stageIndex,
    required String label,
    String memberType = 'external',
    List<double> center = const [0.0, 0.0],
  }) =>
      {
        'stage_index': stageIndex,
        'label': label,
        'member_type': memberType,
        'group_id': 'g1',
        'center': center,
        'outline_points': [
          [1.0, 0.0],
          [0.0, 1.0],
        ],
        'pitch_radius': 20.0,
      };

  Map<String, dynamic> chainPreviewResponse({List<Map<String, dynamic>> findings = const []}) => {
        'gear_kind': 'chain',
        'outline_points': [],
        'warnings': [],
        'chain': {
          'members': [
            member(stageIndex: 0, label: 'single'),
            member(stageIndex: 1, label: 'single', center: const [35.0, 0.0]),
          ],
          'interference_findings': findings,
          'links': [
            {
              'from_stage_index': 0,
              'to_stage_index': 1,
              'kind': 'mesh',
              'ratio': 0.75,
              'reverses_direction': true,
              'linear_mm_per_revolution': null,
            },
          ],
          'overall_ratio': 0.75,
        },
      };

  Map<String, dynamic> planetaryPreviewResponse() => {
        'gear_kind': 'planetary',
        'outline_points': [],
        'warnings': [],
        'planetary': {
          'members': [
            member(stageIndex: 0, label: 'sun'),
            member(stageIndex: 1, label: 'ring', memberType: 'internal'),
            member(stageIndex: 2, label: 'planet_0', center: const [40.0, 0.0]),
          ],
          'sun_to_planet_ratio': 1.0,
          'planet_to_ring_ratio': 3.0,
        },
      };

  testWidgets('fires a debounced chain preview on load and shows the overall ratio', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        return jsonResponse(chainPreviewResponse());
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/document/gear/preview'));
    expect(find.textContaining('Overall ratio'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('shows a non-blocking interference warning without disabling Create', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => jsonResponse(
            chainPreviewResponse(findings: [
              {
                'stage_index_a': 0,
                'member_label_a': 'single',
                'stage_index_b': 1,
                'member_label_b': 'single',
                'gap': -1.5,
                'kind': 'overlap',
              },
            ]),
          )),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('overlap'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('a blocking 422 disables Create and shows the error', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {'type': 'invalid_gear_preview_parameters', 'detail': 'ring_teeth must exceed sun_teeth'},
            }),
            422,
            headers: {'content-type': 'application/json'},
          )),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('ring_teeth must exceed sun_teeth'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNull);
  });

  testWidgets('switching to Planetary mode fires a planetary preview and shows both ratios', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['gear_kind'] == 'planetary') {
          return jsonResponse(planetaryPreviewResponse());
        }
        return jsonResponse(chainPreviewResponse());
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Planetary'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('Sun'), findsWidgets);
    expect(find.textContaining('Planet'), findsWidgets);
  });

  testWidgets('Create posts a GearChainFeature via createPart + createGearChainFeature', (tester) async {
    final requestedPaths = <String>[];
    Map<String, dynamic>? chainBody;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(chainPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Gear Chain Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/gear-chain-features') {
          chainBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'gear_chain',
            'id': 'chain-1',
            'locked': false,
            'produces': 'body',
            'groups': chainBody!['groups'],
            'stages': chainBody!['stages'],
            'start_direction_degrees': 0.0,
            'print_clearance_margin': 0.2,
          }, status: 201);
        }
        return jsonResponse({'id': 'part-1', 'name': 'Gear Chain Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPaths, contains('POST /document/parts'));
    expect(requestedPaths, contains('POST /document/parts/part-1/gear-chain-features'));
    expect(chainBody?['stages'], hasLength(2));
  });

  testWidgets(
    'Create in Planetary mode job-mode-creates via createPlanetaryGearFeatureJob '
    '(LOD Phase 2 chunk 4)',
    (tester) async {
      final requestedPaths = <String>[];
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          requestedPaths.add('${request.method} ${request.url.path}');
          if (request.url.path == '/document/gear/preview') {
            return jsonResponse(planetaryPreviewResponse());
          }
          if (request.url.path == '/document/parts') {
            return jsonResponse({'id': 'part-1', 'name': 'Planetary Gear Part', 'feature_ids': []}, status: 201);
          }
          if (request.url.path == '/document/parts/part-1/planetary-gear-features/jobs') {
            return jsonResponse({'job_id': 'planetary-job-1', 'status': 'running'}, status: 202);
          }
          return jsonResponse({'id': 'part-1', 'name': 'Planetary Gear Part', 'feature_ids': []});
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: GearChainDesignScreen(documentApi: client, initialMode: GearMultiKind.planetary)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      await tester.ensureVisible(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(requestedPaths, contains('POST /document/parts/part-1/planetary-gear-features/jobs'));
      expect(requestedPaths, isNot(contains('POST /document/parts/part-1/planetary-gear-features')));
    },
  );

  testWidgets('Add stage appends another stage row', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => jsonResponse(chainPreviewResponse())),
    );

    await tester.pumpWidget(MaterialApp(home: GearChainDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Stage 3'), findsNothing);
    await tester.ensureVisible(find.text('Add stage'));
    await tester.tap(find.text('Add stage'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Stage 3'), findsOneWidget);
  });
}
