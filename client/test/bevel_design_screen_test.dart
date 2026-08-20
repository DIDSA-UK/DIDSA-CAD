import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/gear/bevel_design_screen.dart';

/// `docs/gear-design/10-bevel-gear.md`/`11-bevel-pair.md` - widget-level
/// coverage for [BevelDesignScreen], mirroring `gear_chain_design_screen_
/// test.dart`'s own shape: a fake [MockClient] stands in for the real
/// backend, no real network, no OCCT dependency in this screen's own
/// import chain.
void main() {
  // BevelDesignScreen now warms GearPresetStore's cache in initState - see
  // gear_design_screen_test.dart's own identical setUp for why.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> bevelMember({
    required String label,
    double axisAngleDegrees = 0.0,
    double effectiveProfileShift = 0.0,
  }) =>
      {
        'label': label,
        'axis_angle_degrees': axisAngleDegrees,
        'outline_points': [
          [65.0, 36.0],
          [78.0, 43.0],
          [82.0, 35.0],
          [68.0, 29.0],
          [68.0, -29.0],
          [82.0, -35.0],
          [78.0, -43.0],
          [65.0, -36.0],
        ],
        'pitch_line': [
          [68.0, 33.0],
          [80.0, 40.0],
        ],
        'pitch_cone_angle_degrees': 26.565,
        'cone_distance': 89.443,
        'inner_cone_distance': 74.543,
        'pitch_radius': 40.0,
        'face_width': 14.9,
        'effective_profile_shift': effectiveProfileShift,
      };

  Map<String, dynamic> bevelGearPreviewResponse({List<String> warnings = const []}) => {
        'gear_kind': 'bevel_gear',
        'outline_points': [],
        'warnings': warnings,
        'bevel_gear': bevelMember(label: 'single'),
      };

  Map<String, dynamic> bevelMeshPreview() => {
        'member_1_teeth': [
          [
            [40.0, 2.0],
            [44.0, 3.0],
            [44.0, -3.0],
            [40.0, -2.0],
          ],
        ],
        'member_2_teeth': [
          [
            [-4.0, 2.5],
            [-8.0, 3.5],
            [-8.0, -3.5],
            [-4.0, -2.5],
          ],
        ],
        'center_1': [0.0, 0.0],
        'center_2': [80.0, 0.0],
        'pitch_radius_1': 40.0,
        'pitch_radius_2': 40.0,
      };

  Map<String, dynamic> bevelPairPreviewResponse() => {
        'gear_kind': 'bevel_pair',
        'outline_points': [],
        'warnings': [],
        'bevel_pair': {
          'members': [
            bevelMember(label: 'member_1'),
            bevelMember(label: 'member_2', axisAngleDegrees: 90.0),
          ],
          'shaft_angle_degrees': 90.0,
          'mesh_preview': bevelMeshPreview(),
        },
      };

  testWidgets('fires a debounced bevel gear preview on load with no banner when valid', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        return jsonResponse(bevelGearPreviewResponse());
      }),
    );

    await tester.pumpWidget(MaterialApp(home: BevelDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/document/gear/preview'));
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('shows a non-blocking face-width warning without disabling Create', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => jsonResponse(
            bevelGearPreviewResponse(warnings: ['single: face_width exceeds the recommended maximum']),
          )),
    );

    await tester.pumpWidget(MaterialApp(home: BevelDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('face_width exceeds'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('a blocking 422 disables Create and shows the error', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {
                'type': 'invalid_gear_preview_parameters',
                'detail': 'face_width must be less than the cone distance',
              },
            }),
            422,
            headers: {'content-type': 'application/json'},
          )),
    );

    await tester.pumpWidget(MaterialApp(home: BevelDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('face_width must be less than the cone distance'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNull);
  });

  testWidgets('switching to Bevel Pair mode fires a pair preview showing both members', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        if (body['gear_kind'] == 'bevel_pair') {
          return jsonResponse(bevelPairPreviewResponse());
        }
        return jsonResponse(bevelGearPreviewResponse());
      }),
    );

    await tester.pumpWidget(MaterialApp(home: BevelDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Bevel Pair'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Member 1 (pinion)'), findsOneWidget);
    expect(find.text('Member 2 (gear)'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('Create posts a BevelGearFeature via createPart + createBevelGearFeature', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(bevelGearPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Bevel Gear Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/bevel-gear-features') {
          return jsonResponse({
            'type': 'bevel_gear',
            'id': 'bevel-1',
            'locked': false,
            'produces': 'body',
            'bevel_type': 'boss',
            'module': 4.0,
            'tooth_count': 20,
            'face_width': 15.0,
            'pitch_cone_angle_degrees': 30.0,
            'pressure_angle_degrees': 20.0,
            'backlash': 0.0,
            'profile_shift': 0.0,
          }, status: 201);
        }
        return jsonResponse({'id': 'part-1', 'name': 'Bevel Gear Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: BevelDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPaths, contains('POST /document/parts'));
    expect(requestedPaths, contains('POST /document/parts/part-1/bevel-gear-features'));
  });

  testWidgets('Create in Bevel Pair mode posts via createBevelPairFeature', (tester) async {
    final requestedPaths = <String>[];
    Map<String, dynamic>? pairBody;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(bevelPairPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/bevel-pair-features') {
          pairBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'bevel_pair',
            'id': 'pair-1',
            'locked': false,
            'produces': 'body',
            'module': 4.0,
            'member_1': {'tooth_count': 20, 'profile_shift': 0.0},
            'member_2': {'tooth_count': 40, 'profile_shift': 0.0},
            'face_width': 15.0,
            'pressure_angle_degrees': 20.0,
            'shaft_angle_degrees': 90.0,
            'backlash': 0.0,
          }, status: 201);
        }
        return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: BevelDesignScreen(documentApi: client, initialMode: BevelMultiKind.pair)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPaths, contains('POST /document/parts/part-1/bevel-pair-features'));
    expect(pairBody?['shaft_angle_degrees'], 90.0);
    expect((pairBody?['member_1'] as Map)['tooth_count'], 20);
    expect((pairBody?['member_2'] as Map)['tooth_count'], 40);
  });

  testWidgets(
    'Bevel Pair profile shift defaults to Auto, showing the live-computed value and sending null',
    (tester) async {
      Map<String, dynamic>? pairBody;
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          if (request.url.path == '/document/gear/preview') {
            return jsonResponse({
              'gear_kind': 'bevel_pair',
              'outline_points': [],
              'warnings': [],
              'bevel_pair': {
                'members': [
                  bevelMember(label: 'member_1', effectiveProfileShift: 0.0),
                  bevelMember(label: 'member_2', axisAngleDegrees: 90.0, effectiveProfileShift: -0.52),
                ],
                'shaft_angle_degrees': 90.0,
                'mesh_preview': bevelMeshPreview(),
              },
            });
          }
          if (request.url.path == '/document/parts') {
            return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []}, status: 201);
          }
          if (request.url.path == '/document/parts/part-1/bevel-pair-features') {
            pairBody = jsonDecode(request.body) as Map<String, dynamic>;
            return jsonResponse({
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
              'effective_profile_shift_1': 0.0,
              'effective_profile_shift_2': -0.52,
            }, status: 201);
          }
          return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []});
        }),
      );

      await tester.pumpWidget(
        MaterialApp(home: BevelDesignScreen(documentApi: client, initialMode: BevelMultiKind.pair)),
      );
      await tester.pump(const Duration(milliseconds: 600));
      await tester.pumpAndSettle();

      // Both start Auto, and member_2's field shows the live-computed
      // negative shift from the preview response, not a static 0.
      expect(find.text('Auto'), findsNWidgets(2));
      expect(find.widgetWithText(TextField, 'Profile shift'), findsNWidgets(2));
      final shift2Field = tester.widget<TextField>(find.widgetWithText(TextField, 'Profile shift').at(1));
      expect(shift2Field.enabled, isFalse);
      expect(shift2Field.controller?.text, '-0.52');

      await tester.ensureVisible(find.byType(FilledButton));
      await tester.pumpAndSettle();
      await tester.tap(find.byType(FilledButton));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect((pairBody?['member_1'] as Map)['profile_shift'], isNull);
      expect((pairBody?['member_2'] as Map)['profile_shift'], isNull);
    },
  );

  testWidgets('Toggling Bevel Pair profile shift to Manual sends the typed override', (tester) async {
    Map<String, dynamic>? pairBody;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(bevelPairPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/bevel-pair-features') {
          pairBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'bevel_pair',
            'id': 'pair-1',
            'locked': false,
            'produces': 'body',
            'module': 4.0,
            'member_1': {'tooth_count': 20, 'profile_shift': 0.0},
            'member_2': {'tooth_count': 40, 'profile_shift': -0.3},
            'face_width': 15.0,
            'pressure_angle_degrees': 20.0,
            'shaft_angle_degrees': 90.0,
            'backlash': 0.0,
            'effective_profile_shift_1': 0.0,
            'effective_profile_shift_2': -0.3,
          }, status: 201);
        }
        return jsonResponse({'id': 'part-1', 'name': 'Bevel Pair Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(
      MaterialApp(home: BevelDesignScreen(documentApi: client, initialMode: BevelMultiKind.pair)),
    );
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    // Flip member_2's switch to Manual, then type an override. Both the
    // switch and the field sit below the fold in the test's default
    // viewport (800x600) - ensureVisible first, same as the Create button
    // elsewhere in this file, or tap()/enterText() silently miss.
    final member2Switch = find.byType(Switch).at(1);
    await tester.ensureVisible(member2Switch);
    await tester.pumpAndSettle();
    await tester.tap(member2Switch);
    await tester.pumpAndSettle();
    expect(find.text('Manual'), findsOneWidget);
    final member2ShiftField = find.widgetWithText(TextField, 'Profile shift').at(1);
    await tester.ensureVisible(member2ShiftField);
    await tester.pumpAndSettle();
    await tester.enterText(member2ShiftField, '-0.3');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect((pairBody?['member_1'] as Map)['profile_shift'], isNull);
    expect((pairBody?['member_2'] as Map)['profile_shift'], -0.3);
  });
}
