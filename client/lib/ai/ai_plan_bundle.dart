/// External-LLM hand-off, return leg for multi-part work: a `.zip` holding
/// one `part_manifest` JSON, one ordinary plan JSON per part, one assembly
/// plan JSON per sub-assembly the manifest lists (none for a flat assembly),
/// and the top-level assembly plan JSON (the shape an external AI produces when given the
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

  /// One assembly plan per entry of [manifest].subAssemblies, index-aligned, raw like [assemblyJson] - see
  /// [subAssemblyPlanFor]. Built in this order, before the top level, so each may place parts and any earlier
  /// sub-assembly.
  final List<Map<String, dynamic>> subAssemblyJson;

  const AiPlanBundle({
    required this.manifest,
    required this.partPlans,
    required this.assemblyJson,
    this.subAssemblyJson = const [],
  });

  /// Parses [bytes] as a zip. Entries are classified by content, not by
  /// name: the one `"kind": "part_manifest"` object is the manifest; of the
  /// remaining `steps` plans, those containing `add_component` steps are
  /// assemblies and the rest are part plans, taken in file-name order and
  /// matched to the manifest by that order (each name's `NN_` prefix is
  /// what the external AI used to sequence them). Of the assemblies, the
  /// last in file-name order (`99_assembly.json`) is the top level; any
  /// before it are the manifest's `sub_assemblies`, matched the same way.
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
    final assemblies = <({String name, Map<String, dynamic> json})>[];
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
          assemblies.add((name: file.name, json: decoded));
        } else {
          partJson.add(decoded);
        }
      }
    }

    if (manifest == null) throw const AiPlanBundleException('The zip has no part manifest (a JSON with "kind": "part_manifest").');
    if (assemblies.isEmpty) throw const AiPlanBundleException('The zip has no assembly plan (a plan containing add_component steps).');
    final subCount = manifest.subAssemblies.length;
    if (assemblies.length != subCount + 1) {
      throw AiPlanBundleException(
        subCount == 0
            ? 'The zip has ${assemblies.length} assembly plans (${assemblies.map((a) => a.name).join(', ')}) but the '
                'manifest lists no sub_assemblies. List each sub-assembly in the manifest\'s "sub_assemblies", or '
                'keep one assembly plan.'
            : 'The manifest lists $subCount sub-assemblies but the zip has ${assemblies.length - 1} sub-assembly '
                'plans besides the top-level assembly (the last assembly plan by file name).',
      );
    }
    final assemblyJson = assemblies.last.json;
    final subAssemblyJson = [for (final a in assemblies.take(subCount)) a.json];
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
    for (var i = 0; i < subCount; i++) {
      try {
        AiGenerationPlan.fromJson(subAssemblyJson[i]);
      } catch (e) {
        throw AiPlanBundleException('The plan for sub-assembly "${manifest.subAssemblies[i].name}" could not be read: $e');
      }
    }
    final partPlans = <AiGenerationPlan>[];
    for (var i = 0; i < partJson.length; i++) {
      try {
        partPlans.add(AiGenerationPlan.fromJson(partJson[i]));
      } catch (e) {
        throw AiPlanBundleException('The plan for "${manifest.parts[i].name}" could not be read: $e');
      }
    }
    return AiPlanBundle(manifest: manifest, partPlans: partPlans, assemblyJson: assemblyJson, subAssemblyJson: subAssemblyJson);
  }

  /// Display name by original type prefix, for every part and sub-assembly.
  Map<String, String> get _nameByPrefix => {
        for (final part in manifest.parts) sanitizePartTypePrefix(part.typePrefix): part.name,
        for (final sub in manifest.subAssemblies) sanitizePartTypePrefix(sub.typePrefix): sub.name,
      };

  /// The sub-assembly index whose type prefix [relativePath] names, or null.
  int? _subAssemblyIndexOf(String relativePath) {
    final prefix = _prefixOfReference(relativePath);
    for (var i = 0; i < manifest.subAssemblies.length; i++) {
      if (sanitizePartTypePrefix(manifest.subAssemblies[i].typePrefix) == prefix) return i;
    }
    return null;
  }

  List<({String localId, String relativePath, String partName})> _componentsOf(Map<String, dynamic> json, String pathPrefix, int depth) {
    final names = _nameByPrefix;
    final out = <({String localId, String relativePath, String partName})>[];
    for (final step in ((json['steps'] as List?) ?? const []).whereType<Map>()) {
      if (step['kind'] != 'add_component' || step['local_id'] is! String || step['relative_path'] is! String) continue;
      final path = step['relative_path'] as String;
      final localId = '$pathPrefix${step['local_id']}';
      out.add((localId: localId, relativePath: path, partName: names[_prefixOfReference(path)] ?? path));
      final sub = _subAssemblyIndexOf(path);
      if (sub != null && depth < manifest.subAssemblies.length) {
        out.addAll(_componentsOf(subAssemblyJson[sub], '$localId/', depth + 1));
      }
    }
    return out;
  }

  /// The assembly's components as the zip names them: each `add_component` step's `local_id`, its path as written
  /// and the manifest part (or sub-assembly) it belongs to (matched by `<TYPE_PREFIX>_NNN` like [assemblyPlanFor]; the
  /// path itself when nothing matches). A component that is a sub-assembly is followed by the components inside it,
  /// named by path (`wheel_asm/wheel`), the way a top-level mate names them. What an external AI needs to be told
  /// when its mates have to be redone.
  List<({String localId, String relativePath, String partName})> get assemblyComponents => _componentsOf(assemblyJson, '', 0);

  /// The assembly plan with every `add_component` `relative_path` that
  /// referred to one of the manifest's parts replaced by the path that part
  /// was really saved under. [savedPathByIndex] is index-aligned with
  /// [manifest].parts. A reference is matched to a part by its
  /// `<TYPE_PREFIX>_<NNN>` base name against that part's *original* manifest
  /// type prefix (so renaming a prefix in the confirm panel doesn't break
  /// the match); references that match nothing are left untouched and will
  /// fail the normal pre-flight validation with a clear message.
  ///
  /// [savedSubAssemblyPaths] (index-aligned with [manifest].subAssemblies) does the same for a reference to a
  /// sub-assembly's `<TYPE_PREFIX>_NNN`.
  AiGenerationPlan assemblyPlanFor(List<String> savedPathByIndex, {List<String> savedSubAssemblyPaths = const []}) =>
      _planFor(assemblyJson, savedPathByIndex, savedSubAssemblyPaths);

  /// [assemblyPlanFor] for sub-assembly [index]: its references to parts and to earlier sub-assemblies (those in
  /// [savedSubAssemblyPaths], which holds only the ones saved so far) repointed at their saved paths.
  AiGenerationPlan subAssemblyPlanFor(int index, List<String> savedPathByIndex, {List<String> savedSubAssemblyPaths = const []}) =>
      _planFor(subAssemblyJson[index], savedPathByIndex, savedSubAssemblyPaths);

  AiGenerationPlan _planFor(Map<String, dynamic> json, List<String> savedPathByIndex, List<String> savedSubAssemblyPaths) {
    final byPrefix = <String, String>{
      for (var i = 0; i < manifest.parts.length && i < savedPathByIndex.length; i++)
        sanitizePartTypePrefix(manifest.parts[i].typePrefix): savedPathByIndex[i],
      for (var i = 0; i < manifest.subAssemblies.length && i < savedSubAssemblyPaths.length; i++)
        sanitizePartTypePrefix(manifest.subAssemblies[i].typePrefix): savedSubAssemblyPaths[i],
    };
    final rewritten = _rewritePaths(json, byPrefix);
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
