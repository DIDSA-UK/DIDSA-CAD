import '../api/document_api_client.dart';

/// AI Modelling: "Continue with AI" existing-Part editing
/// (`docs/ai-modelling/09-existing-part-editing.md`) - the prompt-facing
/// summary of a Part's current Feature tree, embedded into
/// `ai_scoping_prompt.dart`'s own locked "Editing an existing Part" block.
///
/// **Written for the model, not a human** - every line's whole purpose is
/// to give the LLM the literal `existing:<id>` token it must echo back
/// verbatim to reference that Feature, so the id always comes first and is
/// never elided/abbreviated the way a human-facing feature-tree label
/// might. One line per [FeatureDto], in the Part's own creation order (the
/// order `DocumentApiClient.listFeatures` already returns them in - the
/// same order the real translator walks a plan's steps in, so this reads
/// the same "first this, then this" way a plan does).
///
/// Every Feature is listed, including one that is never a valid
/// `existing:` target at all (`produces == 'none'`/`'surface'`, e.g. an
/// Import Feature) - labelled "not directly referenceable" rather than
/// omitted, so the model still has full context on what the Part contains
/// even where it can't name that specific Feature itself.
String summarizeExistingPartForPrompt(List<FeatureDto> features) {
  final lines = <String>[];
  for (var i = 0; i < features.length; i++) {
    final f = features[i];
    lines.add('${i + 1}. existing:${f.id} - ${_describe(f)} [${_referenceability(f)}]');
  }
  return lines.join('\n');
}

String _referenceability(FeatureDto f) {
  switch (f.produces) {
    case 'body':
      return 'Body - usable as target_body_ids / source_body_ids / tool_feature_id / a fillet-chamfer edges "of"';
    case 'plane':
      return 'Plane - usable as a plane_feature_id';
    case 'sketch':
      return 'Sketch - usable as the sketch_feature_id anchor for brand-new sketch entity steps only, never for '
          'its own existing Points/Lines/etc. directly';
    default:
      return 'not directly referenceable';
  }
}

String _fmt(double? v) {
  if (v == null) return '?';
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  return v.toString();
}

String _describe(FeatureDto f) {
  switch (f.type) {
    case 'sketch':
      return 'sketch (plane ${f.planeFeatureId != null ? 'existing:${f.planeFeatureId}' : 'fixed'})';
    case 'extrude':
      return 'extrude ${_fmt(f.startDistance)}->${_fmt(f.endDistance)}mm (${f.extrudeType ?? '?'})';
    case 'revolve':
      return 'revolve ${_fmt(f.angle)}° (${f.mode ?? '?'})';
    case 'sweep':
      return 'sweep along ${f.pathRefs.length} path(s) (${f.mode ?? '?'})';
    case 'fillet':
      return 'fillet r=${_fmt(f.radius)}mm on ${f.edgeRefs.length} edge(s)';
    case 'chamfer':
      return 'chamfer d=${_fmt(f.distance)}mm on ${f.edgeRefs.length} edge(s)';
    case 'pattern':
      return 'pattern (${f.patternType ?? '?'})';
    case 'mirror':
      return 'mirror';
    case 'create_plane':
      return 'create_plane (${f.planeType ?? '?'})';
    default:
      return f.type;
  }
}
