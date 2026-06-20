import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/main.dart';
import 'package:didsa_cad_client/sketch/sketch_canvas.dart';
import 'package:didsa_cad_client/sketch/sketch_controller.dart';

http.Response _jsonResponse(Map<String, dynamic> body, {int statusCode = 200}) =>
    http.Response(jsonEncode(body), statusCode);

void main() {
  testWidgets('App boots, creates a sketch on startup, and shows controls', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse({'id': 'sketch-1', 'plane': 'XY'}, statusCode: 201);
      }
      return http.Response('not found', 404);
    });

    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Column(
            children: [
              Expanded(child: SketchCanvas(controller: controller)),
            ],
          ),
        ),
      ),
    );

    await controller.ensureSketch();
    await tester.pump();

    expect(controller.sketchId, 'sketch-1');
    expect(controller.errorMessage, isNull);
  });

  testWidgets('DidsaCadApp renders the Click and Finish Line buttons', (tester) async {
    final mockClient = MockClient((request) async {
      if (request.url.path == '/sketch/sketches' && request.method == 'POST') {
        return _jsonResponse({'id': 'sketch-1', 'plane': 'XY'}, statusCode: 201);
      }
      return http.Response('not found', 404);
    });
    final controller = SketchController(api: SketchApiClient(httpClient: mockClient));

    await tester.pumpWidget(DidsaCadApp(controller: controller));
    await tester.pump();

    expect(find.text('Click'), findsOneWidget);
    expect(find.text('Finish Line'), findsOneWidget);
  });
}
