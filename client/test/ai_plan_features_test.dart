import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_features.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';

/// B5 (docs/assembly-perf-mates-and-ui-plan.md): tell the user once that the backend is too old for a plan.
void main() {
  Map<String, dynamic> ref(String occurrence, {Map<String, dynamic>? faceSelector}) => {
        'occurrence_id': occurrence,
        if (faceSelector != null) 'face_selector': faceSelector else 'subshape_ref': {'body_id': 'b', 'shape_type': 'face', 'index': 0},
      };

  AiGenerationPlan plan(List<Map<String, dynamic>> refs) => AiGenerationPlan.fromJson({
        'version': 1,
        'steps': [
          {'local_id': 'm1', 'kind': 'mate', 'type': 'coincident', 'references': refs},
        ],
      });

  test('a plain mate needs nothing special', () {
    expect(requiredApiFeatures(plan([ref('existing:a'), ref('existing:b')])), isEmpty);
  });

  test('a sloped face_selector (normal) and an outer/inner path each name their feature', () {
    final p = plan([
      ref('existing:a', faceSelector: {'normal': [0, 1, 1]}),
      ref('existing:b/c'),
    ]);
    expect(requiredApiFeatures(p), {kFeatureFaceSelectorNormal, kFeatureMatePaths});
  });

  test('missingApiFeatures: an older backend (no api_features) lacks everything used; a current one lacks nothing; unknown claims nothing', () {
    final p = plan([ref('existing:a', faceSelector: {'normal': [0, 1, 1]}), ref('existing:b/c')]);
    expect(missingApiFeatures(p, <String>{}), [kFeatureFaceSelectorNormal, kFeatureMatePaths]);
    expect(missingApiFeatures(p, {kFeatureFaceSelectorNormal, kFeatureMatePaths, 'something.new'}), isEmpty);
    expect(missingApiFeatures(p, {kFeatureMatePaths}), [kFeatureFaceSelectorNormal]);
    expect(missingApiFeatures(p, null), isEmpty, reason: 'a failed /health call is not evidence of an old backend');
  });

  test('the message says the backend is older than the app and what it lacks', () {
    final message = backendTooOldMessage([kFeatureMatePaths]);
    expect(message, startsWith('The backend is older than this app: update it to build these mates'));
    expect(message, contains(kFeatureMatePaths));
  });

  group('DocumentApiClient.apiFeatures', () {
    DocumentApiClient clientFor(http.Response Function(http.Request) handler) =>
        DocumentApiClient(httpClient: MockClient((request) async => handler(request)));

    test('reads the list from GET /health', () async {
      final api = clientFor((request) {
        expect(request.url.path, '/health');
        return http.Response(jsonEncode({'status': 'ok', 'api_features': ['a', 'b']}), 200);
      });
      expect(await api.apiFeatures(), {'a', 'b'});
    });

    test('an older backend answers without the key: an empty set', () async {
      final api = clientFor((_) => http.Response(jsonEncode({'status': 'ok'}), 200));
      expect(await api.apiFeatures(), <String>{});
    });

    test('an unreadable /health gives null (nothing can be claimed)', () async {
      expect(await clientFor((_) => http.Response('nope', 500)).apiFeatures(), isNull);
      expect(await clientFor((_) => http.Response('not json', 200)).apiFeatures(), isNull);
      final throwing = DocumentApiClient(httpClient: MockClient((_) async => throw Exception('offline')));
      expect(await throwing.apiFeatures(), isNull);
    });
  });
}
