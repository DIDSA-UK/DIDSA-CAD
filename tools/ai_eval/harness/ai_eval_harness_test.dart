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
//   AI_EVAL_MANIFEST=<file> AI_EVAL_OUT=<dir>
//                                    Assembly mode: find the part_manifest in a
//                                    reply; write manifest.json, the part
//                                    request turns the app sends
//                                    (requests/part_NN.txt), the file names the
//                                    app proposes for each part, and the
//                                    assembly request turn and its extra
//                                    system-prompt section
//   AI_EVAL_ASSEMBLY=<run dir>       Assembly mode: build every part from
//                                    part_NN_reply.txt (or a later
//                                    part_NN_retry_reply.txt) into one
//                                    document, save each to a real project
//                                    folder, then build assembly_reply.txt
//                                    with add_component reading those files;
//                                    write assembly_result.json, part_NN.step
//                                    and assembly.step
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
import 'package:didsa_cad_client/ai/ai_part_naming.dart';
import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_summary.dart';
import 'package:didsa_cad_client/ai/ai_plan_detection.dart';
import 'package:didsa_cad_client/ai/ai_plan_translator.dart';
import 'package:didsa_cad_client/ai/ai_provider.dart';
import 'package:didsa_cad_client/ai/ai_scoping_prompt.dart';
import 'package:didsa_cad_client/ai/ai_validation_feedback.dart';
import 'package:didsa_cad_client/api/document_api_client.dart';
import 'package:didsa_cad_client/api/sketch_api_client.dart';
import 'package:didsa_cad_client/assembly/assembly_document_client.dart';
import 'package:didsa_cad_client/assembly/relative_path.dart';
import 'package:didsa_cad_client/storage/desktop_storage_service.dart';
import 'package:didsa_cad_client/storage/project_root.dart';

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
    // AI_EVAL_MODE=assembly: the Assembly toggle instead, in a fresh, empty project folder (no
    // "Available Component Files" section until the assembly turn).
    final assembly = env['AI_EVAL_MODE'] == 'assembly';
    File('$out/system_prompt.txt').writeAsStringSync(
      buildAiScopingSystemPrompt(multiBodyPartMode: !assembly, assemblyMode: assembly),
    );
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
  test('manifest', () {
    final replyPath = env['AI_EVAL_MANIFEST'];
    if (replyPath == null) return;
    final out = env['AI_EVAL_OUT']!;
    final manifest = detectPartManifestInAssistantText(File(replyPath).readAsStringSync());
    if (manifest == null) {
      File('$out/manifest.json').writeAsStringSync(_json.convert({'detected': false}));
      return;
    }
    Directory('$out/requests').createSync(recursive: true);
    // The names the save dialog proposes, part by part, in an empty project folder.
    final saved = <String>[];
    final paths = <String>[];
    for (var i = 0; i < manifest.parts.length; i++) {
      final e = manifest.parts[i];
      final path = withDefaultExtension(nextAvailablePartName(saved, typePrefix: e.typePrefix));
      saved.add(path);
      paths.add(path);
      File('$out/requests/part_${_nn(i + 1)}.txt').writeAsStringSync(
        assemblyModePartRequestText(index: i, total: manifest.parts.length, name: e.name, summary: e.summary),
      );
    }
    final listing = [for (var i = 0; i < paths.length; i++) '${i + 1}. ${paths[i]} - "${manifest.parts[i].name}"'].join('\n');
    File('$out/requests/assembly.txt').writeAsStringSync(assemblyModeAssemblyRequestText(listing));
    // The assembly turn's system prompt is the same one plus an "Available Component Files" section.
    final base = buildAiScopingSystemPrompt(assemblyMode: true);
    final withFiles = buildAiScopingSystemPrompt(assemblyMode: true, availableComponentFilesSummary: listing);
    File('$out/requests/assembly_system_section.txt').writeAsStringSync(_insertedText(base, withFiles));
    File('$out/manifest.json').writeAsStringSync(_json.convert({
      'detected': true,
      'parts': [
        for (var i = 0; i < manifest.parts.length; i++)
          {'name': manifest.parts[i].name, 'type_prefix': manifest.parts[i].typePrefix, 'summary': manifest.parts[i].summary, 'path': paths[i]},
      ],
    }));
  });

  test('run assembly', () async {
    final runDir = env['AI_EVAL_ASSEMBLY'];
    if (runDir == null) return;
    final manifest = jsonDecode(File('$runDir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    final parts = (manifest['parts'] as List).cast<Map<String, dynamic>>();
    final client = _LiveClient(Uri.parse(env['AI_EVAL_BACKEND'] ?? 'http://127.0.0.1:8000'), env['CAD_API_KEY'] ?? 'local-test-key');
    final docApi = DocumentApiClient(httpClient: client);
    final sketchApi = SketchApiClient(httpClient: client);
    final projectDir = Directory('$runDir/project');
    if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    projectDir.createSync(recursive: true);
    final root = DesktopProjectRoot(projectDir.absolute.path);
    final storage = DesktopStorageService();
    final assemblyClient = AssemblyDocumentClient(storageService: storage, documentApiClient: docApi);
    final report = <String, dynamic>{'parts': <Map<String, dynamic>>[]};
    void save() => File('$runDir/assembly_result.json').writeAsStringSync(_json.convert(report));
    for (final f in Directory(runDir).listSync().whereType<File>()) {
      if (f.path.endsWith('retry_request.txt') && !f.path.contains('/requests/')) f.deleteSync();
    }

    await docApi.startNewDocument();
    for (var i = 0; i < parts.length; i++) {
      final n = _nn(i + 1);
      final retry = File('$runDir/part_${n}_retry_reply.txt');
      final replyFile = retry.existsSync() ? retry : File('$runDir/part_${n}_reply.txt');
      final entry = <String, dynamic>{'name': parts[i]['name'], 'path': parts[i]['path'], 'retried': retry.existsSync()};
      (report['parts'] as List).add(entry);
      if (!replyFile.existsSync()) {
        entry['outcome'] = 'no reply';
        report['stopped'] = 'part $n: no reply';
        return save();
      }
      final plan = detectPlanInAssistantText(replyFile.readAsStringSync());
      if (plan == null) {
        entry['outcome'] = 'no plan';
        report['stopped'] = 'part $n: no plan';
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          'That reply was not a plan for "${parts[i]['name']}" - please reply with an ordinary plan for this '
          'part only, as described in the Assembly mode instructions.\n\n${assemblyModePartRetryRequestText(name: parts[i]['name'] as String)}',
        );
        return save();
      }
      File('$runDir/part_${n}_plan.json').writeAsStringSync(_json.convert(plan.toJson()));
      final part = await docApi.createPart(parts[i]['name'] as String);
      final result = await PlanTranslator(documentApi: docApi, sketchApi: sketchApi, storageService: storage, projectRoot: root)
          .execute(plan: plan, partId: part.id);
      entry['outcome'] = result.outcome.name;
      entry['error'] = result.errorMessage;
      entry['stopped_at'] = result.stoppedAtLocalId;
      if (result.outcome == PlanTranslationOutcome.validationFailed) {
        entry['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
        // The app appends the failure and retries automatically, once.
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          'For "${parts[i]['name']}": ${describeAiPlanValidationFailure(plan, result.preflightResults)}\n\n'
          '${assemblyModePartRequestText(index: i, total: parts.length, name: parts[i]['name'] as String, summary: '')}',
        );
        report['stopped'] = 'part $n: validation failed';
        return save();
      }
      if (result.outcome != PlanTranslationOutcome.success) {
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          '${_stoppedRunText(plan, result)}\n\n${assemblyModePartRetryRequestText(name: parts[i]['name'] as String)}',
        );
        report['stopped'] = 'part $n: ${result.outcome.name}';
        return save();
      }
      final step = await client.get(Uri.parse('/document/parts/${part.id}/export/step'));
      if (step.statusCode == 200) File('$runDir/part_$n.step').writeAsBytesSync(step.bodyBytes);
      await assemblyClient.savePart(root, part.id, parts[i]['path'] as String);
    }

    final asmReply = File('$runDir/assembly_retry_reply.txt').existsSync()
        ? File('$runDir/assembly_retry_reply.txt')
        : File('$runDir/assembly_reply.txt');
    report['assembly'] = <String, dynamic>{'retried': asmReply.path.endsWith('retry_reply.txt')};
    final asm = report['assembly'] as Map<String, dynamic>;
    if (!asmReply.existsSync()) {
      asm['outcome'] = 'no reply';
      return save();
    }
    final plan = detectPlanInAssistantText(asmReply.readAsStringSync());
    if (plan == null) {
      asm['outcome'] = 'no plan';
      return save();
    }
    File('$runDir/assembly_plan.json').writeAsStringSync(_json.convert(plan.toJson()));
    final asmPart = await docApi.createPart('Assembly');
    final result = await PlanTranslator(documentApi: docApi, sketchApi: sketchApi, storageService: storage, projectRoot: root)
        .execute(plan: plan, partId: asmPart.id);
    asm['outcome'] = result.outcome.name;
    asm['error'] = result.errorMessage;
    asm['stopped_at'] = result.stoppedAtLocalId;
    if (result.outcome == PlanTranslationOutcome.validationFailed) {
      asm['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
      File('$runDir/assembly_retry_request.txt').writeAsStringSync(
        'For the assembly plan: ${describeAiPlanValidationFailure(plan, result.preflightResults)}\n\n'
        '${assemblyModeAssemblyRetryRequestText()}',
      );
    } else if (result.outcome != PlanTranslationOutcome.success) {
      File('$runDir/assembly_retry_request.txt').writeAsStringSync(
        '${_stoppedRunText(plan, result)}\n\n${assemblyModeAssemblyRetryRequestText()}',
      );
    }
    final step = await client.get(Uri.parse('/document/parts/${asmPart.id}/export/assembly-step'));
    asm['step_status'] = step.statusCode;
    if (step.statusCode == 200) File('$runDir/assembly.step').writeAsBytesSync(step.bodyBytes);
    save();
  }, timeout: const Timeout(Duration(minutes: 10)));
}

String _nn(int i) => i.toString().padLeft(2, '0');

/// The text `buildAiScopingSystemPrompt` inserts for an "Available Component Files" section.
String _insertedText(String base, String withExtra) {
  var a = 0;
  while (a < base.length && base[a] == withExtra[a]) {
    a++;
  }
  var b = 0;
  while (b < base.length - a && base[base.length - 1 - b] == withExtra[withExtra.length - 1 - b]) {
    b++;
  }
  return withExtra.substring(a, withExtra.length - b).trim();
}

/// `AiModellingScreen._appendStoppedRunToTranscript`'s text for a step failure.
String _stoppedRunText(AiGenerationPlan plan, PlanTranslationResult result) {
  final summary = summarizeAiPlan(plan);
  final nonPointSteps = plan.steps.where((s) => s is! AiSketchPointStep).toList();
  final stepPosition = nonPointSteps.indexWhere((s) => s.localId == result.stoppedAtLocalId);
  final description = stepPosition >= 0 && stepPosition < summary.length
      ? '${stepPosition + 1}. ${summary[stepPosition]}'
      : '${result.stoppedAtLocalId}';
  return 'Execution stopped at step $description: ${result.errorMessage}\n\n'
      'Every step before this one was created successfully and is still in the Part '
      '(no automatic rollback - use "Undo this generation" to remove them, or continue '
      'manually). Please propose a revised plan for the remaining steps.';
}
