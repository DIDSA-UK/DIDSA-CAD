/// AI Modelling: per-tool-group enable/disable toggles a user can set in AI
/// Settings -> Tools, each gating one section of the scoping conversation's
/// system prompt (`ai_scoping_prompt.dart`) AND the plan-step `kind`s that
/// section documents - unlike `ai_prompt_addons.dart`'s add-ons (purely
/// additive prompt guidance that never changes what the LLM can build), a
/// tool-group toggle is subtractive and must be enforced, not just worded:
/// see `PlanTranslator.execute`/`DocumentApiClient.validateAiPlan`'s own
/// `disabledKinds` parameter, which this file's `kinds` field feeds.
library;

import 'ai_scoping_prompt.dart';

class AiToolGroup {
  final String label;

  /// Plan-step `kind` strings this group covers - fed to
  /// `DocumentApiClient.validateAiPlan`'s `disabledKinds` (flattened across
  /// every currently-disabled group) so a disabled tool is rejected
  /// server-side, not just omitted from the prompt.
  final Set<String> kinds;

  /// The `## ...` markdown block appended to the system prompt when this
  /// group is enabled - sourced from `ai_scoping_prompt.dart`'s own
  /// `*VocabularyText` constants (never duplicated here).
  final String vocabularyText;

  /// Human-facing name of the manual UI equivalent, used in both this
  /// screen's own explanatory text and the system prompt's dynamic
  /// "Tools currently turned off" block (`ai_scoping_prompt.dart`).
  final String manualToolHint;

  const AiToolGroup({
    required this.label,
    required this.kinds,
    required this.vocabularyText,
    required this.manualToolHint,
  });
}

/// Keyed by a stable id (persisted in `AiSystemPromptPreferences.
/// disabledToolGroups`) - never rename a key once shipped, same rule
/// `aiPromptAddOns`'s own doc comment states for add-on ids.
///
/// Grouping is by natural vocabulary-section boundary, not by individual
/// JSON `kind` - Fillet+Chamfer share one switch since they share one large
/// edge-selector block and are almost always wanted together; the five
/// Direct-Editing/Boolean kinds share one switch since each is a few lines
/// and nobody will want Merge on but Boolean off. Splitting a group later
/// is a small, additive change (add a new id, no other change needed).
const Map<String, AiToolGroup> aiToolGroups = {
  'revolve': AiToolGroup(
    label: 'Revolve',
    kinds: {'revolve'},
    vocabularyText: revolveVocabularyText,
    manualToolHint: 'the Revolve tool in the Feature toolbar',
  ),
  'sweep': AiToolGroup(
    label: 'Sweep',
    kinds: {'sweep'},
    vocabularyText: sweepVocabularyText,
    manualToolHint: 'the Sweep tool in the Feature toolbar',
  ),
  'loft': AiToolGroup(
    label: 'Loft',
    kinds: {'loft'},
    vocabularyText: loftVocabularyText,
    manualToolHint: 'the Loft tool in the Feature toolbar',
  ),
  'fillet_chamfer': AiToolGroup(
    label: 'Fillet & Chamfer',
    kinds: {'fillet', 'chamfer'},
    vocabularyText: filletChamferVocabularyText,
    manualToolHint: 'the Fillet/Chamfer tool in the Feature toolbar',
  ),
  'pattern': AiToolGroup(
    label: 'Pattern',
    kinds: {'pattern'},
    vocabularyText: patternVocabularyText,
    manualToolHint: 'the Pattern tool in the Feature toolbar',
  ),
  'mirror': AiToolGroup(
    label: 'Mirror',
    kinds: {'mirror'},
    vocabularyText: mirrorVocabularyText,
    manualToolHint: 'the Mirror tool in the Feature toolbar',
  ),
  'create_plane': AiToolGroup(
    label: 'Reference Planes',
    kinds: {'create_plane'},
    vocabularyText: createPlaneVocabularyText,
    manualToolHint: 'the Reference Plane tool in the Feature toolbar',
  ),
  'gear_routing': AiToolGroup(
    label: 'Gear Design routing',
    kinds: {'gear_request'},
    vocabularyText: gearRoutingVocabularyText,
    manualToolHint: 'the Gear Design tool',
  ),
  'direct_editing_boolean': AiToolGroup(
    label: 'Direct Editing & Boolean',
    kinds: {'merge', 'boolean', 'delete_body', 'scale_body', 'move_body'},
    vocabularyText: directEditingBooleanVocabularyText,
    manualToolHint: 'the Direct Editing / Boolean tools in the Feature toolbar',
  ),
};

/// Never shown as a toggle, never disableable - sketch primitives and
/// Extrude are the floor almost every plan needs; making them optional
/// would break nearly every request for negligible token savings (their
/// vocabulary text is already unavoidable boilerplate, unlike a whole
/// feature family). Not read by [aiToolGroups] itself - documented here so
/// a future toggle addition doesn't accidentally try to gate one of these.
const Set<String> aiCoreToolKinds = {
  'sketch',
  'sketch_point',
  'sketch_line',
  'sketch_circle',
  'sketch_arc',
  'sketch_ellipse',
  'sketch_polygon',
  'sketch_slot',
  'sketch_rectangle',
  'extrude',
};
