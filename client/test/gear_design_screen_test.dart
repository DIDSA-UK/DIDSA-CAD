import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/gear/gear_design_screen.dart';

/// `docs/gear-design/08-entry-screen-and-preview.md`: widget-level coverage
/// for [GearDesignScreen] - the debounced `/gear/preview` call, the
/// non-blocking validation banner (undercut-risk warning vs. a blocking
/// invalid-parameter 422), and "Create" posting to the right endpoint per
/// gear kind. A fake [MockClient] stands in for the real backend, same
/// convention `document_api_client_test.dart` already uses - no real
/// network, no `flutter_scene`/OCCT dependency in this screen's own import
/// chain (unlike `PartScreen` itself, which this only navigates *to* after
/// Create, never builds inline here).
void main() {
  // GearDesignScreen now warms GearPresetStore's cache in initState -
  // shared_preferences has no real platform channel under `flutter test`,
  // so every test needs the mock in place, same as part_screen_test.dart's
  // own setUp.
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, dynamic> defaultPreviewResponse({List<String> warnings = const []}) => {
        'gear_kind': 'external',
        'outline_points': [
          [1.0, 0.0],
          [0.0, 1.0],
        ],
        'pitch_radius': 20.0,
        'base_radius': 18.79,
        'addendum_radius': 22.0,
        'dedendum_radius': 17.5,
        'warnings': warnings,
      };

  testWidgets('fires a debounced /gear/preview call on load and shows no banner when valid', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add(request.url.path);
        return jsonResponse(defaultPreviewResponse());
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(requestedPaths, contains('/document/gear/preview'));
    expect(find.textContaining('undercut'), findsNothing);
    expect(find.byType(FilledButton), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('shows the non-blocking undercut warning without disabling Create', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => jsonResponse(
            defaultPreviewResponse(warnings: ['Tooth count 6 is below the undercut-free minimum - undercut.']),
          )),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('undercut'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNotNull);
  });

  testWidgets('a blocking 422 disables Create and shows the error, not a warning banner', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'detail': {'type': 'invalid_gear_preview_parameters', 'detail': 'tooth_count must be >= 4, got 3'},
            }),
            422,
            headers: {'content-type': 'application/json'},
          )),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.textContaining('tooth_count must be >= 4'), findsOneWidget);
    final createButton = tester.widget<FilledButton>(find.byType(FilledButton));
    expect(createButton.onPressed, isNull);
  });

  testWidgets('switching to Internal reveals the required outer-diameter field', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        if (request.url.path == '/document/gear/preview') {
          final body = jsonDecode(request.body) as Map<String, dynamic>;
          if (body['gear_kind'] == 'internal') {
            return jsonResponse({
              'gear_kind': 'internal',
              'outline_points': [
                [1.0, 0.0],
              ],
              'pitch_radius': 40.0,
              'outer_radius': 50.0,
              'warnings': [],
            });
          }
          return jsonResponse(defaultPreviewResponse());
        }
        return jsonResponse({});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Outer diameter (required)'), findsNothing);

    await tester.tap(find.text('Internal'));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Outer diameter (required)'), findsOneWidget);
  });

  testWidgets('Create posts a GearFeature via createPart + createGearFeature', (tester) async {
    final requestedPaths = <String>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(defaultPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Gear Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/gear-features') {
          return jsonResponse({
            'type': 'gear',
            'id': 'gear-1',
            'locked': false,
            'produces': 'body',
            'gear_type': 'boss',
            'is_internal': false,
            'module': 2.0,
            'tooth_count': 20,
            'face_width': 5.0,
            'pressure_angle_degrees': 20.0,
            'profile_shift': 0.0,
            'backlash': 0.0,
            'root_fillet_radius': 0.0,
          }, status: 201);
        }
        // PartScreen (navigated to after Create) fetches the Part/mesh -
        // just enough of a fake response so the navigation doesn't crash.
        return jsonResponse({'id': 'part-1', 'name': 'Gear Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPaths, contains('POST /document/parts'));
    expect(requestedPaths, contains('POST /document/parts/part-1/gear-features'));
  });

  testWidgets('Herringbone toggle only appears once a non-zero helix angle is entered, and posts both fields',
      (tester) async {
    final requestedPaths = <String>[];
    Map<String, dynamic>? gearFeatureBody;
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        requestedPaths.add('${request.method} ${request.url.path}');
        if (request.url.path == '/document/gear/preview') {
          return jsonResponse(defaultPreviewResponse());
        }
        if (request.url.path == '/document/parts') {
          return jsonResponse({'id': 'part-1', 'name': 'Gear Part', 'feature_ids': []}, status: 201);
        }
        if (request.url.path == '/document/parts/part-1/gear-features') {
          gearFeatureBody = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({
            'type': 'gear',
            'id': 'gear-1',
            'locked': false,
            'produces': 'body',
            'gear_type': 'boss',
            'is_internal': false,
            'module': 2.0,
            'tooth_count': 20,
            'face_width': 5.0,
            'pressure_angle_degrees': 20.0,
            'profile_shift': 0.0,
            'backlash': 0.0,
            'root_fillet_radius': 0.0,
            'helix_angle_degrees': 15.0,
            'herringbone': true,
          }, status: 201);
        }
        return jsonResponse({'id': 'part-1', 'name': 'Gear Part', 'feature_ids': []});
      }),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    expect(find.text('Herringbone'), findsNothing);

    await tester.enterText(find.widgetWithText(TextField, 'Helix angle'), '15');
    await tester.pump();
    expect(find.text('Herringbone'), findsOneWidget);

    await tester.tap(find.widgetWithText(SwitchListTile, 'Herringbone'));
    await tester.pump();

    await tester.ensureVisible(find.byType(FilledButton));
    await tester.pumpAndSettle();
    await tester.tap(find.byType(FilledButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    expect(requestedPaths, contains('POST /document/parts/part-1/gear-features'));
    expect(gearFeatureBody?['helix_angle_degrees'], 15.0);
    expect(gearFeatureBody?['herringbone'], true);
  });

  testWidgets('tapping a field help icon shows its tooltip instead of opening the field', (tester) async {
    // On-device feedback: the "?" help icon next to the Module dropdown
    // originally lost the tap to the surrounding `DropdownButtonFormField`'s
    // own tap-to-open handling (opened the dropdown instead of the
    // tooltip) - fixed by routing the tap through a real `IconButton`
    // (`FieldHelpIcon`) rather than relying on `Tooltip`'s own automatic
    // gesture detection. Regression guard for that fix, on the exact field
    // (Module, a dropdown - the case that broke) rather than a plain
    // `TextField` (which never had the bug).
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => http.Response(
            jsonEncode({
              'gear_kind': 'external',
              'outline_points': [
                [1.0, 0.0],
              ],
              'pitch_radius': 20.0,
              'warnings': [],
            }),
            200,
            headers: {'content-type': 'application/json'},
          )),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.tap(find.byIcon(Icons.help_outline).first);
    await tester.pump();

    // The dropdown's own menu must NOT have opened - "0.75" (a standard
    // module value that isn't the current selection) is only visible once
    // the full options list renders, unlike the closed state's single
    // selected-value display.
    expect(find.text('0.75'), findsNothing);
    // The tooltip's own message text is now showing.
    expect(
      find.text('Tooth size - pitch diameter divided by tooth count. Larger module means larger, '
          'stronger teeth for the same tooth count.'),
      findsOneWidget,
    );
  });

  testWidgets('Save as preset then Load preset round-trips the tooth count field', (tester) async {
    final client = DocumentApiClient(
      httpClient: MockClient((request) async => jsonResponse(defaultPreviewResponse())),
    );

    await tester.pumpWidget(MaterialApp(home: GearDesignScreen(documentApi: client)));
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.enterText(find.widgetWithText(TextField, 'Tooth count'), '24');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Save as preset'));
    await tester.tap(find.text('Save as preset'));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Preset name'), 'My 24-tooth gear');
    await tester.tap(find.text('Save'));
    await tester.pumpAndSettle();

    // Change the field away from the saved value, so loading the preset
    // back is a real, observable change.
    await tester.enterText(find.widgetWithText(TextField, 'Tooth count'), '30');
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();

    await tester.ensureVisible(find.text('Load preset'));
    await tester.tap(find.text('Load preset'));
    await tester.pumpAndSettle();
    expect(find.text('My 24-tooth gear'), findsOneWidget);
    await tester.tap(find.text('My 24-tooth gear'));
    await tester.pumpAndSettle();

    final toothCountField = tester.widget<TextField>(find.widgetWithText(TextField, 'Tooth count'));
    expect(toothCountField.controller?.text, '24');
  });
}
