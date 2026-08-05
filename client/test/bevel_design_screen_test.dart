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

  Map<String, dynamic> _bevelMember({required String label, double axisAngleDegrees = 0.0}) => {
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
      };

  Map<String, dynamic> bevelGearPreviewResponse({List<String> warnings = const []}) => {
        'gear_kind': 'bevel_gear',
        'outline_points': [],
        'warnings': warnings,
        'bevel_gear': _bevelMember(label: 'single'),
      };

  Map<String, dynamic> bevelPairPreviewResponse() => {
        'gear_kind': 'bevel_pair',
        'outline_points': [],
        'warnings': [],
        'bevel_pair': {
          'members': [
            _bevelMember(label: 'member_1'),
            _bevelMember(label: 'member_2', axisAngleDegrees: 90.0),
          ],
          'shaft_angle_degrees': 90.0,
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
}
