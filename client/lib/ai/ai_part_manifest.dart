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

  const AiPartManifest({required this.parts});

  factory AiPartManifest.fromJson(Map<String, dynamic> json) {
    final raw = json['parts'];
    if (raw is! List || raw.isEmpty) {
      throw const FormatException('Part manifest has no parts');
    }
    return AiPartManifest(
      parts: raw.map((p) => AiPartManifestEntry.fromJson(p as Map<String, dynamic>)).toList(),
    );
  }
}
