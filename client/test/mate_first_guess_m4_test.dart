import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:material_ui/material_ui.dart';
import 'package:vector_math/vector_math.dart' as vm;

import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/viewport3d/mate_panel.dart';
import 'package:didsa_cad_client/viewport3d/mate_pick_point.dart';

/// M4 (`docs/mates-storage-sessions-plan-2026-11-12.md`, "A better first guess"): the panel starts on the type the backend suggests
/// for the picks and the user can still change it; `suggested_type` / `pick_points` on the wire; where a pick landed, local to its
/// occurrence.
void main() {
  http.Response jsonResponse(Object body, {int status = 200}) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  const refs = [
    MateEntityRefDto(occurrenceId: 'occ-1', subshapeRef: SubShapeRefDto(bodyId: 'b1', shapeType: 'edge', index: 2)),
    MateEntityRefDto(occurrenceId: 'occ-2', subshapeRef: SubShapeRefDto(bodyId: 'b2', shapeType: 'edge', index: 5)),
  ];

  group('MateSolvePreviewDto.suggestedType', () {
    test('reads a suggestion', () {
      final dto = MateSolvePreviewDto.fromJson({'converged': true, 'suggested_type': 'peg_in_hole'});
      expect(dto.suggestedType, 'peg_in_hole');
      expect(dto.suggestionAnswered, isTrue);
    });

    test('a null suggestion is an answer: no suggestion for these picks', () {
      final dto = MateSolvePreviewDto.fromJson({'converged': false, 'suggested_type': null});
      expect(dto.suggestedType, isNull);
      expect(dto.suggestionAnswered, isTrue);
    });

    test('absent (an answer to a typed request, or a backend that predates M4) reads as no answer', () {
      final dto = MateSolvePreviewDto.fromJson({'converged': true});
      expect(dto.suggestedType, isNull);
      expect(dto.suggestionAnswered, isFalse);
    });
  });

  group('the wire', () {
    test('previewMateSolve sends type auto, pick_points and view_direction, and reads the suggestion', () async {
      Map<String, dynamic> body = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({'converged': true, 'suggested_type': 'concentric', 'members': []});
        }),
      );
      final result = await client.previewMateSolve(
        'part-1',
        'occ-2',
        type: 'auto',
        references: refs,
        pickPoints: const [
          [1.0, 2.0, 3.0],
          null,
        ],
        viewDirection: const [0.0, 0.0, -1.0],
      );
      expect(body['type'], 'auto');
      expect(body['pick_points'], [
        [1.0, 2.0, 3.0],
        null,
      ]);
      expect(body['view_direction'], [0.0, 0.0, -1.0]);
      expect(result.suggestedType, 'concentric');
    });

    test('without pick points nothing new is sent (the request an older backend knows)', () async {
      Map<String, dynamic> body = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({'converged': true});
        }),
      );
      await client.previewMateSolve('part-1', 'occ-2', type: 'coincident', references: refs);
      expect(body.containsKey('pick_points'), isFalse);
      expect(body.containsKey('view_direction'), isFalse);
    });

    test('createMate sends a peg in a hole as one request, with its pick points', () async {
      Map<String, dynamic> body = {};
      final client = DocumentApiClient(
        httpClient: MockClient((request) async {
          body = jsonDecode(request.body) as Map<String, dynamic>;
          return jsonResponse({'id': 'm1', 'type': 'concentric', 'references': []}, status: 201);
        }),
      );
      await client.createMate(
        'part-1',
        type: kPegInHoleMateType,
        references: refs,
        solve: 'auto',
        pickPoints: const [
          [5.0, 0.0, 20.0],
          [35.0, 20.0, 10.0],
        ],
      );
      expect(body['type'], 'peg_in_hole');
      expect(body['pick_points'], hasLength(2));
      expect(body.containsKey('view_direction'), isFalse);
    });
  });

  group('starting on the suggestion', () {
    test('asks for the type once the two picks are made, until the user picks one by hand', () {
      expect(mateAsksForSuggestedType(userChoseType: false, picksComplete: true, type: 'coincident'), isTrue);
      expect(mateAsksForSuggestedType(userChoseType: false, picksComplete: false, type: 'coincident'), isFalse);
      expect(mateAsksForSuggestedType(userChoseType: true, picksComplete: true, type: 'distance'), isFalse);
      // Width and Symmetric pick four / three faces: never asked
      expect(mateAsksForSuggestedType(userChoseType: false, picksComplete: true, type: 'width'), isFalse);
    });

    test('the panel takes the suggestion, and keeps its type when there is none', () {
      expect(mateTypeAfterSuggestion('coincident', const MateSolvePreviewDto(converged: true, suggestedType: 'peg_in_hole', suggestionAnswered: true)), 'peg_in_hole');
      expect(mateTypeAfterSuggestion('coincident', const MateSolvePreviewDto(converged: false, suggestionAnswered: true)), 'coincident');
      expect(mateTypeAfterSuggestion('concentric', const MateSolvePreviewDto(converged: true)), 'concentric');
    });

    test('Peg in hole is a new-mate type after Concentric, and keeps Allow rotation', () {
      expect(kNewMateTypes.sublist(0, 3), ['coincident', 'concentric', kPegInHoleMateType]);
      expect(mateTypeLabel(kPegInHoleMateType), 'Peg in hole');
      expect(mateTypeHasAllowRotation(kPegInHoleMateType), isTrue);
      expect(kMateTypes.contains(kPegInHoleMateType), isFalse); // a stored mate is never one
    });
  });

  group('MatePanel with a suggestion', () {
    Widget panel({required String mateType, String? suggestedType, ValueChanged<String>? onType}) => MaterialApp(
          home: Scaffold(
            body: MatePanel(
              selectedEntities: const {},
              bodyNames: const {},
              mateType: mateType,
              value: null,
              suggestedType: suggestedType,
              onMateTypeChanged: onType ?? (_) {},
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

    testWidgets('starts on the suggested type and says it was suggested', (tester) async {
      await tester.pumpWidget(panel(mateType: kPegInHoleMateType, suggestedType: kPegInHoleMateType));
      expect(find.text('Peg in hole'), findsOneWidget);
      expect(find.text(kMateSuggestedTypeNote), findsOneWidget);
    });

    testWidgets('the user can change it: the choice is reported and the note goes', (tester) async {
      String? chosen;
      await tester.pumpWidget(panel(mateType: 'concentric', suggestedType: 'concentric', onType: (t) => chosen = t));
      await tester.tap(find.text('Concentric'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Distance').last);
      await tester.pumpAndSettle();
      expect(chosen, 'distance');
      // the parent now shows the user's type: no "suggested" note under it
      await tester.pumpWidget(panel(mateType: 'distance', suggestedType: 'concentric'));
      expect(find.text(kMateSuggestedTypeNote), findsNothing);
      expect(find.text('Distance'), findsOneWidget);
    });

    testWidgets('no suggestion: no note', (tester) async {
      await tester.pumpWidget(panel(mateType: 'coincident'));
      expect(find.text(kMateSuggestedTypeNote), findsNothing);
    });
  });

  group('pick points', () {
    AssemblyOccurrenceInstanceDto instance(String path, RigidTransformDto at) =>
        AssemblyOccurrenceInstanceDto(occurrencePath: path.split('/'), partId: 'p', worldTransform: at);

    test('a hit point is taken into its occurrence\'s own frame', () {
      // the occurrence turned 90 degrees about z and moved by (100, 0, 0): its local (10, 0, 5) is at world (100, 10, 5) (float32 maths)
      final at = RigidTransformDto(translation: [100.0, 0.0, 0.0], rotationAxis: [0.0, 0.0, 1.0], rotationAngleDegrees: 90.0);
      final local = occurrenceLocalPoint(vm.Vector3(100.0, 10.0, 5.0), [instance('asm/occ-1', at)], 'asm/occ-1')!;
      expect(local[0], closeTo(10.0, 1e-4));
      expect(local[1], closeTo(0.0, 1e-4));
      expect(local[2], closeTo(5.0, 1e-4));
      expect(occurrenceLocalPoint(vm.Vector3.zero(), [instance('asm/occ-1', at)], 'occ-9'), isNull);
    });

    test('pick_points follow the references\' order; none at all sends nothing', () {
      final picks = {
        'b': const MatePickPoint(local: [1.0, 2.0, 3.0], viewDirection: [0.0, 0.0, -1.0]),
      };
      expect(matePickPointsFor(['a', 'b'], picks), [
        null,
        [1.0, 2.0, 3.0],
      ]);
      expect(matePickPointsFor(['a', 'c'], picks), isNull);
      expect(mateViewDirectionFor(['a', 'b'], picks), [0.0, 0.0, -1.0]);
      expect(mateViewDirectionFor(['a'], picks), isNull);
    });
  });
}
