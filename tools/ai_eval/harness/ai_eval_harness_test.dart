// AI modelling evaluation harness (tools/ai_eval/README.md). Not part of the
// client's test suite: tools/ai_eval/eval.sh copies it into client/test/ for
// one run and removes it again. It stands in for AiModellingScreen around a
// model that is driven by hand, and uses the app's own code for every step:
//   AI_EVAL_DUMP_PROMPTS=<dir>       write system_prompt.txt and
//                                    extraction_prompt.txt exactly as the app
//                                    sends them (its default settings)
//   AI_EVAL_REPLY=<file> AI_EVAL_OUT=<dir>
//                                    find the plan in an assistant reply, run
//                                    the real PlanTranslator against the
//                                    backend, write result.json and model.step;
//                                    on a validation failure retry_request.txt
//                                    (the app's automatic-retry turn); on
//                                    success drawing.png and check_prompt.txt
//                                    (the app's render-back check inputs)
//   AI_EVAL_VERDICT=<file> AI_EVAL_OUT=<dir>
//                                    parse a render-back check reply; write
//                                    verdict.json and, unless it matched,
//                                    fix_request.txt (the "Ask the AI to fix
//                                    it" turn)
// Backend: AI_EVAL_BACKEND (default http://127.0.0.1:8000), CAD_API_KEY.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:didsa_cad_client/ai/ai_model_check.dart';
import 'package:didsa_cad_client/ai/ai_plan_detection.dart';
import 'package:didsa_cad_client/ai/ai_plan_translator.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';
import 'package:didsa_cad_client/ai/ai_validation_feedback.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';

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
    req.headers['X-Document-Session'] = 'ai-eval';
    if (request is http.Request) req.bodyBytes = request.bodyBytes;
    return _inner.send(req);
  }
}

const _json = JsonEncoder.withIndent('  ');

void main() {
  final env = Platform.environment;

  test('dump prompts', () {
    final out = env['AI_EVAL_DUMP_PROMPTS'];
    if (out == null) return;
    Directory(out).createSync(recursive: true);
    // AiModellingScreen's defaults: no override, no add-ons, no disabled
    // tool groups, Multi-body Part mode (AiGenerationModePreferences).
    File('$out/system_prompt.txt').writeAsStringSync(buildAiScopingSystemPrompt(multiBodyPartMode: true));
    File('$out/extraction_prompt.txt').writeAsStringSync(aiImageExtractionPrompt);
  });

  test('parse verdict', () {
    final verdictPath = env['AI_EVAL_VERDICT'];
    if (verdictPath == null) return;
    final out = env['AI_EVAL_OUT']!;
    final check = parseAiModelCheck(File(verdictPath).readAsStringSync());
    File('$out/verdict.json').writeAsStringSync(_json.convert({'matches': check.matches, 'details': check.details}));
    if (check.matches != true) File('$out/fix_request.txt').writeAsStringSync(aiModelCheckFixRequest(check.details));
  });

  test('run plan', () async {
    final replyPath = env['AI_EVAL_REPLY'];
    if (replyPath == null) return;
    final outDir = Directory(env['AI_EVAL_OUT']!)..createSync(recursive: true);
    final out = outDir.path;
    final client = _LiveClient(Uri.parse(env['AI_EVAL_BACKEND'] ?? 'http://127.0.0.1:8000'), env['CAD_API_KEY'] ?? 'local-test-key');
    final report = <String, dynamic>{};
    void save() => File('$out/result.json').writeAsStringSync(_json.convert(report));

    final plan = detectPlanInAssistantText(File(replyPath).readAsStringSync());
    report['plan_detected'] = plan != null;
    if (plan == null) return save();
    File('$out/plan.json').writeAsStringSync(_json.convert(plan.toJson()));
    report['step_count'] = plan.steps.length;

    final docApi = DocumentApiClient(httpClient: client);
    await docApi.startNewDocument();
    final part = await docApi.createPart('AI Modelling Part');
    report['part_id'] = part.id;

    final result = await PlanTranslator(documentApi: docApi, sketchApi: SketchApiClient(httpClient: client))
        .execute(plan: plan, partId: part.id);
    report['outcome'] = result.outcome.name;
    report['error'] = result.errorMessage;
    report['stopped_at'] = result.stoppedAtLocalId;
    report['preflight'] = [
      for (final r in result.preflightResults)
        {'local_id': r.localId, 'ok': r.ok, if (r.warnings.isNotEmpty) 'warnings': r.warnings, if (r.error != null) 'error': r.error}
    ];
    save();

    if (result.outcome == PlanTranslationOutcome.validationFailed) {
      File('$out/retry_request.txt').writeAsStringSync(describeAiPlanValidationFailure(plan, result.preflightResults));
      return;
    }
    final step = await client.get(Uri.parse('/document/parts/${part.id}/export/step'));
    if (step.statusCode == 200) File('$out/model.step').writeAsBytesSync(step.bodyBytes);
    if (result.outcome == PlanTranslationOutcome.success) {
      final drawing = await docApi.getPartDrawing(part.id);
      File('$out/drawing.png').writeAsBytesSync(drawing.png);
      File('$out/check_prompt.txt').writeAsStringSync(
        buildAiModelCheckPrompt(sketchCount: 1, boundingBoxSize: drawing.boundingBoxSize),
      );
    }
  }, timeout: const Timeout(Duration(minutes: 5)));
}
