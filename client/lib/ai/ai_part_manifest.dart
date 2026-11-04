/// AI Modelling multi-part/assembly overhaul, Phase D
/// (`docs/ai-modelling/13-multi-part-assembly-overhaul.md`): the structured
/// shape the LLM emits in Assembly mode once it has identified the distinct
/// parts a request needs, *before* any real plan for any one of them -
/// `AiGenerationPlan`'s own sibling one level up. Deliberately a different
/// top-level shape (`"kind": "part_manifest"` instead of `"steps": [...]`)
/// so `detectPlanInAssistantText`/`detectPartManifestInAssistantText`
/// (`ai_plan_detection.dart`) can never mistake one for the other.
library;

/// One recognized part - the exact fields `nextAvailablePartName`
/// (`ai_part_naming.dart`) and the per-part plan-request turn both need.
class AiPartManifestEntry {
  final String name;
  final String typePrefix;
  final String summary;

  const AiPartManifestEntry({required this.name, required this.typePrefix, required this.summary});

  factory AiPartManifestEntry.fromJson(Map<String, dynamic> json) => AiPartManifestEntry(
        name: json['name'] as String,
        typePrefix: json['type_prefix'] as String,
        summary: json['summary'] as String? ?? '',
      );

  Map<String, dynamic> toJson() => {'name': name, 'type_prefix': typePrefix, 'summary': summary};
}

class AiPartManifest {
  final List<AiPartManifestEntry> parts;

  /// The readings the assistant had to make that the drawing does not settle (a hard-to-read number, a quantity,
  /// a position, how two parts fit), one short sentence each, for the user to confirm or correct on the confirm
  /// panel before anything is built. Empty when there were none.
  final List<String> assumptions;

  /// Sub-assemblies an imported zip builds between its parts and the top-level assembly (`ai_plan_bundle.dart`), in
  /// build order: each is saved as its own assembly file, and a later one (or the top level) places it by its
  /// `type_prefix` like a part. Empty for a flat assembly, and always empty for the in-app flow, which does not ask
  /// for them.
  final List<AiPartManifestEntry> subAssemblies;

  const AiPartManifest({required this.parts, this.assumptions = const [], this.subAssemblies = const []});

  factory AiPartManifest.fromJson(Map<String, dynamic> json) {
    final raw = json['parts'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('Part manifest has no parts');
    }
    final assumptions = json['assumptions'];
    final subAssemblies = json['sub_assemblies'];
    return AiPartManifest(
      parts: raw.map((p) => AiPartManifestEntry.fromJson(p as Map<String, dynamic>)).toList(),
      assumptions: assumptions is List ? [for (final a in assumptions) if (a is String && a.trim().isNotEmpty) a.trim()] : const [],
      subAssemblies: subAssemblies is List
          ? [for (final s in subAssemblies) AiPartManifestEntry.fromJson(s as Map<String, dynamic>)]
          : const [],
    );
  }
}
