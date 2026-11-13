import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/mate_panel.dart';

/// M4.1 (`docs/mates-storage-sessions-plan-2026-11-12.md`): a Distance previewed where the parts already are - no value typed yet, the
/// preview asks the backend to measure (`measure_value`), the ghost holds that distance and the value box starts on it.
void main() {
  http.Response jsonResponse(Object body) => http.Response(jsonEncode(body), 200, headers: {'content-type': 'application/json'});

  const refs = [
    MateEntityRefDto(occurrenceId: 'occ-1', subshapeRef: SubShapeRefDto(bodyId: 'b1', shapeType: 'face', index: 2)),
    MateEntityRefDto(occurrenceId: 'occ-2', subshapeRef: SubShapeRefDto(bodyId: 'b2', shapeType: 'face', index: 5)),
  ];

  group('MateSolvePreviewDto.measuredValue', () {
    test('reads the measured distance', () {
      final dto = MateSolvePreviewDto.fromJson({'converged': true, 'measured_value': 17.401});
      expect(dto.measuredValue, 17.401);
      expect(dto.measureAnswered, isTrue);
    });

    test('null: asked, but the picks cannot be measured; absent: not asked (or an older backend)', () {
      final none = MateSolvePreviewDto.fromJson({'converged': false, 'measured_value': null});
      expect(none.measuredValue, isNull);
      expect(none.measureAnswered, isTrue);
      final absent = MateSolvePreviewDto.fromJson({'converged': false});
      expect(absent.measureAnswered, isFalse);
    });
  });

  test('previewMateSolve sends measure_value only when asked, and no value', () async {
    final bodies = <Map<String, dynamic>>[];
    final client = DocumentApiClient(
      httpClient: MockClient((request) async {
        bodies.add(jsonDecode(request.body) as Map<String, dynamic>);
        return jsonResponse({'converged': true, 'measured_value': 4.5});
      }),
    );
    final measured = await client.previewMateSolve('part-1', 'occ-2', type: 'distance', references: refs, measureValue: true);
    await client.previewMateSolve('part-1', 'occ-2', type: 'distance', references: refs, value: 6.0);
    expect(bodies[0]['measure_value'], isTrue);
    expect(bodies[0].containsKey('value'), isFalse);
    expect(measured.measuredValue, 4.5);
    expect(bodies[1].containsKey('measure_value'), isFalse);
  });

  test('a Distance with nothing typed is measured once per pair of picks', () {
    expect(mateMeasuresValue(type: 'distance', value: null, askingType: false, picksKey: 'a', measuredKey: null), isTrue);
    expect(mateMeasuresValue(type: 'distance', value: null, askingType: false, picksKey: 'a', measuredKey: 'a'), isFalse); // already measured
    expect(mateMeasuresValue(type: 'distance', value: 6.0, askingType: false, picksKey: 'a', measuredKey: null), isFalse); // the user typed one
    expect(mateMeasuresValue(type: 'distance', value: null, askingType: true, picksKey: 'a', measuredKey: null), isFalse); // the type is being suggested
    expect(mateMeasuresValue(type: 'angle', value: null, askingType: false, picksKey: 'a', measuredKey: null), isFalse);
  });

  group('MatePanel', () {
    Widget panel({double? value, double? measured, int generation = 0}) => MaterialApp(
          home: Scaffold(
            body: MatePanel(
              selectedEntities: const {},
              bodyNames: const {},
              mateType: 'distance',
              value: value,
              measuredValue: measured,
              valueFieldGeneration: generation,
              onMateTypeChanged: (_) {},
              onValueChanged: (_) {},
              allowRotation: true,
              onAllowRotationChanged: (_) {},
              saving: false,
              error: null,
              onConfirm: null,
              onCancel: () {},
            ),
          ),
        );

    testWidgets('the value box starts on the measured distance and says so', (tester) async {
      await tester.pumpWidget(panel());
      expect(find.text(kMateMeasuredValueNote), findsNothing);
      await tester.pumpWidget(panel(value: 17.401, measured: 17.401, generation: 1)); // the parent filled it in from the answer
      expect(find.text('17.401'), findsOneWidget);
      expect(find.text(kMateMeasuredValueNote), findsOneWidget);
    });

    testWidgets('once the user types their own distance the note goes', (tester) async {
      await tester.pumpWidget(panel(value: 6.0, measured: 17.401, generation: 1));
      expect(find.text(kMateMeasuredValueNote), findsNothing);
    });
  });
}
