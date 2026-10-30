/// External-LLM hand-off, return leg for multi-part work: a `.zip` holding
/// one `part_manifest` JSON, one ordinary plan JSON per part, and one
/// assembly plan JSON (the shape an external AI produces when given the
/// Assembly-mode hand-off from `ai_plan_export.dart`). Parsing is pure - the
/// screen (`AiModellingScreen`) feeds the result into its existing
/// manifest-confirm / part-cycle / assembly-cycle orchestration instead of
/// asking the in-app provider for each plan.
library;

import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';

import 'ai_part_manifest.dart';
import 'ai_part_naming.dart';
import 'ai_plan.dart';

class AiPlanBundleException implements Exception {
  final String message;
  const AiPlanBundleException(this.message);

  @override
  String toString() => message;
}

class AiPlanBundle {
  final AiPartManifest manifest;

  /// Index-aligned with [manifest].parts.
  final List<AiGenerationPlan> partPlans;

  /// Kept as raw JSON: the `relative_path` of each `add_component` step has
  /// to be rewritten to the names the parts were actually saved under
  /// before it can be parsed - see [assemblyPlanFor].
  final Map<String, dynamic> assemblyJson;

  const AiPlanBundle({required this.manifest, required this.partPlans, required this.assemblyJson});

  /// Parses [bytes] as a zip. Entries are classified by content, not by
  /// name: the one `"kind": "part_manifest"` object is the manifest; of the
  /// remaining `steps` plans, the one containing `add_component` steps is
  /// the assembly and the rest are part plans, taken in file-name order and
  /// matched to the manifest by that order (each name's `NN_` prefix is
  /// what the external AI used to sequence them).
  factory AiPlanBundle.fromZipBytes(Uint8List bytes) {
    final Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (e) {
      throw AiPlanBundleException('Not a readable zip file: $e');
    }
    final files = archive.files
        .where((f) => f.isFile && f.name.toLowerCase().endsWith('.json') && !f.name.contains('__MACOSX'))
        .toList()
      ..sort((a, b) => a.name.compareTo(b.name));

    AiPartManifest? manifest;
    final partJson = <Map<String, dynamic>>[];
    Map<String, dynamic>? assemblyJson;
    for (final file in files) {
      final Object? decoded;
      try {
        decoded = jsonDecode(utf8.decode(file.content as List<int>));
      } catch (e) {
        throw AiPlanBundleException('"${file.name}" is not valid JSON: $e');
      }
      if (decoded is! Map<String, dynamic>) continue;
      if (decoded['kind'] == 'part_manifest') {
        if (manifest != null) throw const AiPlanBundleException('The zip contains more than one part manifest.');
        manifest = AiPartManifest.fromJson(decoded);
      } else if (decoded['steps'] is List) {
        final isAssembly = (decoded['steps'] as List).any((s) => s is Map && s['kind'] == 'add_component');
        if (isAssembly) {
          if (assemblyJson != null) throw const AiPlanBundleException('The zip contains more than one assembly plan.');
          assemblyJson = decoded;
        } else {
          partJson.add(decoded);
        }
      }
    }

    if (manifest == null) throw const AiPlanBundleException('The zip has no part manifest (a JSON with "kind": "part_manifest").');
    if (assemblyJson == null) throw const AiPlanBundleException('The zip has no assembly plan (a plan containing add_component steps).');
    if (partJson.length != manifest.parts.length) {
      throw AiPlanBundleException(
        'The manifest lists ${manifest.parts.length} parts but the zip has ${partJson.length} part plans.',
      );
    }
    try {
      AiGenerationPlan.fromJson(assemblyJson);
    } catch (e) {
      throw AiPlanBundleException('The assembly plan could not be read: $e');
    }
    final partPlans = <AiGenerationPlan>[];
    for (var i = 0; i < partJson.length; i++) {
      try {
        partPlans.add(AiGenerationPlan.fromJson(partJson[i]));
      } catch (e) {
        throw AiPlanBundleException('The plan for "${manifest.parts[i].name}" could not be read: $e');
      }
    }
    return AiPlanBundle(manifest: manifest, partPlans: partPlans, assemblyJson: assemblyJson);
  }

  /// The assembly plan with every `add_component` `relative_path` that
  /// referred to one of the manifest's parts replaced by the path that part
  /// was really saved under. [savedPathByIndex] is index-aligned with
  /// [manifest].parts. A reference is matched to a part by its
  /// `<TYPE_PREFIX>_<NNN>` base name against that part's *original* manifest
  /// type prefix (so renaming a prefix in the confirm panel doesn't break
  /// the match); references that match nothing are left untouched and will
  /// fail the normal pre-flight validation with a clear message.
  AiGenerationPlan assemblyPlanFor(List<String> savedPathByIndex) {
    final byPrefix = <String, String>{
      for (var i = 0; i < manifest.parts.length && i < savedPathByIndex.length; i++)
        sanitizePartTypePrefix(manifest.parts[i].typePrefix): savedPathByIndex[i],
    };
    final rewritten = _rewritePaths(assemblyJson, byPrefix);
    return AiGenerationPlan.fromJson(rewritten as Map<String, dynamic>);
  }
}

Object? _rewritePaths(Object? node, Map<String, String> byPrefix) {
  if (node is Map) {
    return {
      for (final e in node.entries)
        e.key as String: (e.key == 'relative_path' && e.value is String)
            ? (byPrefix[_prefixOfReference(e.value as String)] ?? e.value)
            : _rewritePaths(e.value, byPrefix),
    };
  }
  if (node is List) return [for (final v in node) _rewritePaths(v, byPrefix)];
  return node;
}

final RegExp _sequenced = RegExp(r'^(.+)_\d+$');

String _prefixOfReference(String path) {
  final file = path.split(RegExp(r'[/\\]')).last;
  final dot = file.lastIndexOf('.');
  final base = dot < 0 ? file : file.substring(0, dot);
  final match = _sequenced.firstMatch(base);
  return sanitizePartTypePrefix(match == null ? base : match.group(1)!);
}
