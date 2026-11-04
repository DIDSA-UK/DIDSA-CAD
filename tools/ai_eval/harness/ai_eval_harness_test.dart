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
//   AI_EVAL_DUMP_HANDOFF=<dir>      the Assembly-mode hand-off package exactly as "Share with
//                                    external AI" builds it (handoff.md): all an external chat is given
//   AI_EVAL_IMPORT=<run dir>         the external route: read <run dir>/external.zip with AiPlanBundle (the
//                                    app's importer), build every part from it, then the assembly the way the app
//                                    does (placements, then the zip's own mates with their local ids rewritten),
//                                    and the completeness check; the same outputs as AI_EVAL_ASSEMBLY
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

import 'package:didsa_cad_client/ai/ai_assembly_report.dart';
import 'package:didsa_cad_client/ai/ai_existing_part_summary.dart';
import 'package:didsa_cad_client/ai/ai_model_check.dart';
import 'package:didsa_cad_client/ai/ai_part_naming.dart';
import 'package:didsa_cad_client/ai/ai_plan.dart';
import 'package:didsa_cad_client/ai/ai_plan_bundle.dart';
import 'package:didsa_cad_client/ai/ai_plan_export.dart';
import 'package:didsa_cad_client/ai/ai_plan_split.dart';
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

  test('dump handoff', () {
    final out = env['AI_EVAL_DUMP_HANDOFF'];
    if (out == null) return;
    Directory(out).createSync(recursive: true);
    // `AiModellingScreen._shareExternalHandoff` in Assembly mode with nothing said yet: the images are attached in
    // the external chat by hand, so the package is all there is.
    File('$out/handoff.md').writeAsStringSync(buildExternalHandoffPackage(
      systemPrompt: buildAiScopingSystemPrompt(assemblyMode: true, externalHandoff: true),
      transcript: const [],
      assemblyMode: true,
    ));
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
      'assumptions': manifest.assumptions,
      'parts': [
        for (var i = 0; i < manifest.parts.length; i++)
          {'name': manifest.parts[i].name, 'type_prefix': manifest.parts[i].typePrefix, 'summary': manifest.parts[i].summary, 'path': paths[i]},
      ],
    }));
  });

  test('corrections', () {
    final corrections = env['AI_EVAL_CORRECTIONS'];
    if (corrections == null) return;
    final out = env['AI_EVAL_OUT']!;
    Directory('$out/requests').createSync(recursive: true);
    File('$out/requests/corrections.txt').writeAsStringSync(assemblyModeCorrectionsText(File(corrections).readAsStringSync().trim()));
  });

  test('run assembly', () async {
    final runDir = env['AI_EVAL_ASSEMBLY'];
    if (runDir == null) return;
    final manifest = jsonDecode(File('$runDir/manifest.json').readAsStringSync()) as Map<String, dynamic>;
    final parts = (manifest['parts'] as List).cast<Map<String, dynamic>>();
    final env_ = _Env.open(runDir, env);
    for (final f in Directory(runDir).listSync().whereType<File>()) {
      if (f.path.endsWith('retry_request.txt') && !f.path.contains('/requests/')) f.deleteSync();
    }
    if (!await _buildParts(env_, parts, (i) async {
      final n = _nn(i + 1);
      final retry = File('$runDir/part_${n}_retry_reply.txt');
      final replyFile = retry.existsSync() ? retry : File('$runDir/part_${n}_reply.txt');
      if (!replyFile.existsSync()) return (plan: null, retried: false, why: 'no reply');
      return (plan: detectPlanInAssistantText(replyFile.readAsStringSync()), retried: retry.existsSync(), why: 'no plan');
    }, retryTurns: true)) return;

    final asmReply = File('$runDir/assembly_retry_reply.txt').existsSync()
        ? File('$runDir/assembly_retry_reply.txt')
        : File('$runDir/assembly_reply.txt');
    env_.report['assembly'] = <String, dynamic>{'retried': asmReply.path.endsWith('retry_reply.txt')};
    final asm = env_.report['assembly'] as Map<String, dynamic>;
    if (!asmReply.existsSync()) {
      asm['outcome'] = 'no reply';
      return env_.save();
    }
    final plan = detectPlanInAssistantText(asmReply.readAsStringSync());
    if (plan == null) {
      asm['outcome'] = 'no plan';
      return env_.save();
    }
    await _runAssemblyPlan(env_, plan, imported: false);
  }, timeout: const Timeout(Duration(minutes: 10)));

  // The external route: the zip an external chat produced, through the app's own importer and assembly cycle.
  test('run import', () async {
    final runDir = env['AI_EVAL_IMPORT'];
    if (runDir == null) return;
    final env_ = _Env.open(runDir, env);
    final AiPlanBundle bundle;
    try {
      bundle = AiPlanBundle.fromZipBytes(File('$runDir/external.zip').readAsBytesSync());
    } on AiPlanBundleException catch (e) {
      env_.report['stopped'] = 'zip: ${e.message}';
      return env_.save();
    }
    // The names the save dialog proposes in an empty project folder, as `manifest` computes them.
    final saved = <String>[];
    final paths = <String>[];
    for (final part in bundle.manifest.parts) {
      final path = withDefaultExtension(nextAvailablePartName(saved, typePrefix: part.typePrefix));
      saved.add(path);
      paths.add(path);
    }
    File('$runDir/manifest.json').writeAsStringSync(_json.convert({
      'detected': true,
      'assumptions': bundle.manifest.assumptions,
      'parts': [
        for (var i = 0; i < paths.length; i++)
          {
            'name': bundle.manifest.parts[i].name,
            'type_prefix': bundle.manifest.parts[i].typePrefix,
            'summary': bundle.manifest.parts[i].summary,
            'path': paths[i],
          },
      ],
    }));
    final parts = (jsonDecode(File('$runDir/manifest.json').readAsStringSync())['parts'] as List).cast<Map<String, dynamic>>();
    if (!await _buildParts(env_, parts, (i) async => (plan: bundle.partPlans[i], retried: false, why: 'no plan'), retryTurns: false)) {
      return;
    }
    final plan = bundle.assemblyPlanFor(paths);
    env_.report['assembly'] = <String, dynamic>{'retried': false};
    await _runAssemblyPlan(env_, plan, imported: true);
  }, timeout: const Timeout(Duration(minutes: 10)));
}

/// What one assembly build shares: the live backend, a fresh real project folder, the report written as
/// assembly_result.json.
class _Env {
  _Env._(this.runDir, this.client, this.docApi, this.sketchApi, this.root, this.storage);
  final String runDir;
  final http.Client client;
  final DocumentApiClient docApi;
  final SketchApiClient sketchApi;
  final DesktopProjectRoot root;
  final DesktopStorageService storage;
  final Map<String, dynamic> report = {'parts': <Map<String, dynamic>>[]};

  static _Env open(String runDir, Map<String, String> env) {
    final client = _LiveClient(Uri.parse(env['AI_EVAL_BACKEND'] ?? 'http://127.0.0.1:8000'), env['CAD_API_KEY'] ?? 'local-test-key');
    final projectDir = Directory('$runDir/project');
    if (projectDir.existsSync()) projectDir.deleteSync(recursive: true);
    projectDir.createSync(recursive: true);
    return _Env._(runDir, client, DocumentApiClient(httpClient: client), SketchApiClient(httpClient: client),
        DesktopProjectRoot(projectDir.absolute.path), DesktopStorageService());
  }

  void save() => File('$runDir/assembly_result.json').writeAsStringSync(_json.convert(report));
}

typedef _PartPlan = ({AiGenerationPlan? plan, bool retried, String why});

/// Builds every manifest part into one document and saves each to the project folder, as `_runPartCycle` does.
/// [planFor] gives each part's plan (null: [_PartPlan.why] says why not). [retryTurns]: write the retry request the
/// app would send on a failure (an imported plan is fixed, so there is none). False when it stopped.
Future<bool> _buildParts(
  _Env e,
  List<Map<String, dynamic>> parts,
  Future<_PartPlan> Function(int index) planFor, {
  required bool retryTurns,
}) async {
  final runDir = e.runDir;
  final assemblyClient = AssemblyDocumentClient(storageService: e.storage, documentApiClient: e.docApi);
  await e.docApi.startNewDocument();
  for (var i = 0; i < parts.length; i++) {
    final n = _nn(i + 1);
    final got = await planFor(i);
    final entry = <String, dynamic>{'name': parts[i]['name'], 'path': parts[i]['path'], 'retried': got.retried};
    (e.report['parts'] as List).add(entry);
    final plan = got.plan;
    if (plan == null) {
      entry['outcome'] = got.why;
      e.report['stopped'] = 'part $n: ${got.why}';
      if (retryTurns && got.why == 'no plan') {
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          'That reply was not a plan for "${parts[i]['name']}" - please reply with an ordinary plan for this '
          'part only, as described in the Assembly mode instructions.\n\n${assemblyModePartRetryRequestText(name: parts[i]['name'] as String)}',
        );
      }
      e.save();
      return false;
    }
    File('$runDir/part_${n}_plan.json').writeAsStringSync(_json.convert(plan.toJson()));
    final part = await e.docApi.createPart(parts[i]['name'] as String);
    final result = await PlanTranslator(documentApi: e.docApi, sketchApi: e.sketchApi, storageService: e.storage, projectRoot: e.root)
        .execute(plan: plan, partId: part.id);
    entry['outcome'] = result.outcome.name;
    entry['error'] = result.errorMessage;
    entry['stopped_at'] = result.stoppedAtLocalId;
    if (result.outcome == PlanTranslationOutcome.validationFailed) {
      entry['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
      if (retryTurns) {
        // The app appends the failure and retries automatically, once.
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          'For "${parts[i]['name']}": ${describeAiPlanValidationFailure(plan, result.preflightResults)}\n\n'
          '${assemblyModePartRequestText(index: i, total: parts.length, name: parts[i]['name'] as String, summary: '')}',
        );
      }
      e.report['stopped'] = 'part $n: validation failed';
      e.save();
      return false;
    }
    if (result.outcome != PlanTranslationOutcome.success) {
      if (retryTurns) {
        File('$runDir/part_${n}_retry_request.txt').writeAsStringSync(
          '${_stoppedRunText(plan, result)}\n\n${assemblyModePartRetryRequestText(name: parts[i]['name'] as String)}',
        );
      }
      e.report['stopped'] = 'part $n: ${result.outcome.name}';
      e.save();
      return false;
    }
    final step = await e.client.get(Uri.parse('/document/parts/${part.id}/export/step'));
    if (step.statusCode == 200) File('$runDir/part_$n.step').writeAsBytesSync(step.bodyBytes);
    await assemblyClient.savePart(e.root, part.id, parts[i]['path'] as String);
  }
  return true;
}

/// `AiModellingScreen._runAssemblyCycle` from the plan on, for the harness: the placements (a plan that carries its own
/// mates is split, `ai_plan_split.dart`), then the mates - the plan's own with their local ids rewritten, or for an
/// in-app plan without any the app's second turn (`_mateTurn`) - then the completeness check, then the STEP export.
Future<void> _runAssemblyPlan(_Env e, AiGenerationPlan plan, {required bool imported}) async {
  final runDir = e.runDir;
  final asm = e.report['assembly'] as Map<String, dynamic>;
  File('$runDir/assembly_plan.json').writeAsStringSync(_json.convert(plan.toJson(includeIntendedMotion: true)));
  final asmPart = await e.docApi.createPart('Assembly');
  final split = splitPlacementAndMates(plan);
  final placement = split.placement ?? plan;
  final translator = PlanTranslator(documentApi: e.docApi, sketchApi: e.sketchApi, storageService: e.storage, projectRoot: e.root);
  final result = await translator.execute(plan: placement, partId: asmPart.id);
  asm['outcome'] = result.outcome.name;
  asm['error'] = result.errorMessage;
  asm['stopped_at'] = result.stoppedAtLocalId;
  if (result.outcome == PlanTranslationOutcome.validationFailed) {
    asm['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
    if (!imported) {
      File('$runDir/assembly_retry_request.txt').writeAsStringSync(
        'For the assembly plan: ${describeAiPlanValidationFailure(placement, result.preflightResults)}\n\n'
        '${assemblyModeAssemblyRetryRequestText()}',
      );
    }
  } else if (result.outcome != PlanTranslationOutcome.success && !imported) {
    File('$runDir/assembly_retry_request.txt').writeAsStringSync(
      '${_stoppedRunText(placement, result)}\n\n${assemblyModeAssemblyRetryRequestText()}',
    );
  }
  var intended = <AiIntendedMotion>[];
  if (result.outcome == PlanTranslationOutcome.success) {
    if (split.mates.isNotEmpty || imported) {
      final componentIds = addComponentLocalIds(placement);
      final placed = {for (final entry in result.localIdToRealId.entries) if (componentIds.contains(entry.key)) entry.key: entry.value};
      final rewritten = rewriteMateOccurrenceIds(split.mates, placed, intendedMotion: split.intendedMotion);
      intended = rewritten.intendedMotion;
      e.report['mates'] = await _carriedMates(e, rewritten, asmPart.id);
    } else if (plan.steps.any((s) => s is AiAddComponentStep)) {
      e.report['mates'] = await _mateTurn(runDir, e.docApi, e.sketchApi, e.storage, e.root, asmPart.id);
    }
    final mates = e.report['mates'] as Map<String, dynamic>?;
    if (mates != null && mates['outcome'] != 'awaiting reply') {
      e.report['completeness'] = await _completeness(e, asmPart.id, intended);
    }
  }
  final step = await e.client.get(Uri.parse('/document/parts/${asmPart.id}/export/assembly-step'));
  asm['step_status'] = step.statusCode;
  if (step.statusCode == 200) File('$runDir/assembly.step').writeAsBytesSync(step.bodyBytes);
  e.save();
}

/// The mates an assembly plan carried (an imported zip's), run as `AiModellingScreen._runCarriedMates` does: one plan,
/// validated and built once; a failure is recorded, there is no retry (nobody to ask).
Future<Map<String, dynamic>> _carriedMates(_Env e, AiGenerationPlan plan, String assemblyPartId) async {
  if (plan.steps.isEmpty) return {'outcome': 'none in the plan', 'count': 0};
  final out = <String, dynamic>{'carried': true, 'count': plan.steps.whereType<AiMateStep>().length};
  File('${e.runDir}/mates_plan.json').writeAsStringSync(_json.convert(plan.toJson()));
  final PlanTranslationResult result;
  try {
    result = await PlanTranslator(documentApi: e.docApi, sketchApi: e.sketchApi, storageService: e.storage, projectRoot: e.root)
        .execute(plan: plan, partId: assemblyPartId);
  } on ApiException catch (ex) {
    // The validate call refused the plan outright (HTTP 422, a field the schema does not accept): the app records it
    // like a validation failure and saves the placed assembly without mates.
    out['outcome'] = 'validationFailed';
    out['error'] = ex.message;
    File('${e.runDir}/mates_failure.txt').writeAsStringSync(ex.message);
    return out;
  }
  out['outcome'] = result.outcome.name;
  out['error'] = result.errorMessage;
  out['stopped_at'] = result.stoppedAtLocalId;
  if (result.outcome == PlanTranslationOutcome.validationFailed) {
    out['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
    File('${e.runDir}/mates_failure.txt').writeAsStringSync(listAiPlanValidationProblems(plan, result.preflightResults));
  }
  return out;
}

/// The completeness check (`ai_assembly_report.dart`) on the built assembly: completeness.json, one entry per
/// component with its saved path (`external_ref`, how the scorer finds which part it is), its constraint status and
/// free motions, and the intent the plan declared; completeness.txt is the report as the app shows it.
Future<Map<String, dynamic>> _completeness(_Env e, String assemblyPartId, List<AiIntendedMotion> intended) async {
  final occurrences = await e.docApi.listOccurrences(assemblyPartId);
  final status = await e.docApi.getConstraintStatus(assemblyPartId);
  final report = buildCompletenessReport(occurrences: occurrences, status: status, intended: intended);
  Map<String, dynamic> motion(FreeMotionDto m) => {
        'kind': m.kind,
        if (m.direction != null) 'direction': m.direction,
        if (m.axis != null) 'axis': m.axis,
        if (m.through != null) 'through': m.through,
        if (m.pitchPerTurn != null) 'pitch_per_turn': m.pitchPerTurn,
      };
  final components = [
    for (final row in report.rows)
      {
        'occurrence_id': row.occurrenceId,
        'external_ref': [for (final o in occurrences) if (o.id == row.occurrenceId) o.externalRef].first,
        'name': row.name,
        'status': row.state == null ? 'unchecked' : const {
              ConstraintState.fixed: 'fixed',
              ConstraintState.fullyConstrained: 'fully_constrained',
              ConstraintState.underConstrained: 'under_constrained',
              ConstraintState.overConstrained: 'over_constrained',
            }[row.state],
        'dof': row.dof,
        'free_motions': [for (final m in row.freeMotions) motion(m)],
        if (row.intendedMotion != null) 'intended': row.intendedMotion,
      },
  ];
  final out = {'components': components, 'needs_follow_up': report.needsFollowUp};
  File('${e.runDir}/completeness.json').writeAsStringSync(_json.convert(out));
  File('${e.runDir}/completeness.txt').writeAsStringSync(formatCompletenessReport(report, maxRows: 1000));
  return {'components': components.length, 'unintended_free': report.unintendedlyFree.length, 'over': report.overConstrained.length};
}

String _nn(int i) => i.toString().padLeft(2, '0');

/// `AiModellingScreen._runMateTurn` for the harness. The first build writes requests/mates.txt (the app's turn, with
/// the placed components' real ids) and the ids it listed; a later build, once mates_reply.txt exists, maps those ids
/// onto this build's (by order - the same plans place the same components in the same order) and builds the mates.
/// mates_retry_reply.txt, if present, is the reply to requests/mates_retry.txt (the app retries a failed validation
/// once).
Future<Map<String, dynamic>> _mateTurn(String runDir, DocumentApiClient docApi, SketchApiClient sketchApi,
    DesktopStorageService storage, DesktopProjectRoot root, String assemblyPartId) async {
  final occurrences = await docApi.listOccurrences(assemblyPartId);
  final ids = <String>[];
  for (final o in occurrences) {
    ids.add(o.id);
    if (o.resolvedPartId != null) {
      ids.addAll([for (final f in await docApi.listFeatures(o.resolvedPartId!)) if (f.produces == 'body') f.id]);
    }
  }
  final idsFile = File('$runDir/requests/mates_ids.json');
  final reply = File('$runDir/mates_reply.txt');
  if (!reply.existsSync() || !idsFile.existsSync()) {
    Directory('$runDir/requests').createSync(recursive: true);
    idsFile.writeAsStringSync(jsonEncode(ids));
    File('$runDir/requests/mates.txt')
        .writeAsStringSync(assemblyModeMatesRequestText(summarizePlacedComponentsForMates(occurrences)));
    return {'outcome': 'awaiting reply'};
  }
  final listed = (jsonDecode(idsFile.readAsStringSync()) as List).cast<String>();
  String remap(String text) {
    for (var i = 0; i < listed.length && i < ids.length; i++) {
      text = text.replaceAll(listed[i], ids[i]);
    }
    return text;
  }

  final retry = File('$runDir/mates_retry_reply.txt');
  final out = <String, dynamic>{'retried': retry.existsSync()};
  final plan = detectPlanInAssistantText(remap((retry.existsSync() ? retry : reply).readAsStringSync()));
  if (plan == null || plan.steps.isEmpty) return {...out, 'outcome': 'no plan'};
  File('$runDir/mates_plan.json').writeAsStringSync(_json.convert(plan.toJson()));
  out['count'] = plan.steps.whereType<AiMateStep>().length;
  final PlanTranslationResult result;
  try {
    result = await PlanTranslator(documentApi: docApi, sketchApi: sketchApi, storageService: storage, projectRoot: root)
        .execute(plan: plan, partId: assemblyPartId);
  } on ApiException catch (e) {
    // HTTP 422 from the validate call (a field the schema does not accept): the app treats it as a failed validation.
    out['outcome'] = 'validationFailed';
    out['error'] = e.message;
    if (!retry.existsSync()) {
      File('$runDir/requests/mates_retry.txt').writeAsStringSync(
        'For the mates plan: the plan was rejected, so nothing was built: ${e.message}\n\n'
        '${assemblyModeMatesRetryRequestText()}',
      );
    }
    return out;
  }
  out['outcome'] = result.outcome.name;
  out['error'] = result.errorMessage;
  out['stopped_at'] = result.stoppedAtLocalId;
  if (result.outcome == PlanTranslationOutcome.validationFailed) {
    out['preflight'] = [for (final r in result.preflightResults) if (!r.ok) {'local_id': r.localId, 'error': r.error}];
    if (!retry.existsSync()) {
      File('$runDir/requests/mates_retry.txt').writeAsStringSync(
        'For the mates plan: ${describeAiPlanValidationFailure(plan, result.preflightResults)}\n\n'
        '${assemblyModeMatesRetryRequestText()}',
      );
    }
  }
  return out;
}

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
