import 'dart:math' as math;

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart';

/// AI Modelling: "Continue with AI" existing-Part editing
/// (`docs/ai-modelling/09-existing-part-editing.md`) - the prompt-facing
/// summary of a Part's current Feature tree, embedded into
/// `ai_scoping_prompt.dart`'s own locked "Editing an existing Part" block.
///
/// **On-device feedback**: the original Feature-tree-only summary told the
/// LLM an extrude/revolve/sweep existed and its own numbers (0->10mm boss,
/// etc.) but nothing about the Sketch profile it was built from - the model
/// could see "a sketch has been extruded," never the sketch's actual shape
/// or size. Fixed by fetching every real (non-construction) entity in each
/// Sketch Feature (`SketchApiClient.list*` - the same per-type calls
/// `sketch_controller.dart` itself makes when loading a Sketch for editing;
/// there is no single bulk "get everything" endpoint) and rendering a
/// compact geometric description - real dimensions, not raw point/line ids
/// (which the model could never reference anyway - `09`'s own scope rule:
/// an existing Sketch's individual entities are never directly
/// referenceable, only the whole Sketch as an anchor for brand-new ones).
/// Each Body-producing Feature that consumes a Sketch also names it back
/// (`, from existing:<sketch id>`) so the model can connect an extrude's
/// own boss/cut numbers to the real profile that produced them without
/// guessing.
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
Future<String> summarizeExistingPartForPrompt(SketchApiClient sketchApi, List<FeatureDto> features) async {
  final sketchGeometry = <String, String>{};
  for (final f in features) {
    if (f.type == 'sketch' && f.sketchId != null) {
      sketchGeometry[f.sketchId!] = await _summarizeSketchEntities(sketchApi, f.sketchId!);
    }
  }
  final lines = <String>[];
  for (var i = 0; i < features.length; i++) {
    final f = features[i];
    lines.add('${i + 1}. existing:${f.id} - ${_describe(f, sketchGeometry)} [${_referenceability(f)}]');
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

/// [PointDto]s are always fetched alongside every other entity type since
/// Circle/Arc/Polygon/Slot/Rectangle each carry their real dimension
/// directly on their own DTO (radius, or - Rectangle only - computed here
/// from its own corner Points, the same corner0->corner1/corner1->corner2
/// convention `ai_plan_translator.dart`'s width/height dimensioning
/// already uses) but only Points give a usable center/corner position.
Future<String> _summarizeSketchEntities(SketchApiClient sketchApi, String sketchId) async {
  final points = {for (final p in await sketchApi.listPoints(sketchId)) p.id: p};
  final descriptions = <String>[];

  for (final l in await sketchApi.listLines(sketchId)) {
    if (l.construction) continue;
    descriptions.add('line ${_fmt(l.length)}mm long');
  }
  for (final c in await sketchApi.listCircles(sketchId)) {
    if (c.construction) continue;
    final center = points[c.centerPointId];
    descriptions.add('circle r=${_fmt(c.radius)}mm'
        '${center != null ? ' centered at (${_fmt(center.x)},${_fmt(center.y)})' : ''}');
  }
  for (final a in await sketchApi.listArcs(sketchId)) {
    if (a.construction) continue;
    descriptions.add('arc r=${_fmt(a.radius)}mm');
  }
  for (final e in await sketchApi.listEllipses(sketchId)) {
    if (e.construction) continue;
    descriptions.add('ellipse major=${_fmt(e.majorRadius)}mm minor=${_fmt(e.minorRadius)}mm');
  }
  for (final p in await sketchApi.listPolygons(sketchId)) {
    if (p.construction) continue;
    descriptions.add('${p.sides}-sided polygon r=${_fmt(p.radius)}mm');
  }
  for (final s in await sketchApi.listSlots(sketchId)) {
    if (s.construction) continue;
    descriptions.add('slot r=${_fmt(s.radius)}mm');
  }
  for (final r in await sketchApi.listRectangles(sketchId)) {
    if (r.construction) continue;
    final corners = [for (final id in r.cornerPointIds) points[id]].whereType<PointDto>().toList();
    if (corners.length == 4) {
      final width = _distance(corners[0], corners[1]);
      final height = _distance(corners[1], corners[2]);
      descriptions.add('rectangle ${_fmt(width)}x${_fmt(height)}mm');
    } else {
      descriptions.add('rectangle');
    }
  }

  if (descriptions.isEmpty) return 'empty (no real geometry yet)';
  // Caps prompt-size growth from an unusually dense Sketch - the model
  // gets a real count either way, never a silently truncated list with no
  // indication more exists.
  const maxEntities = 20;
  if (descriptions.length > maxEntities) {
    final shown = descriptions.take(maxEntities).join(', ');
    return '$shown, and ${descriptions.length - maxEntities} more entities';
  }
  return descriptions.join(', ');
}

double _distance(PointDto a, PointDto b) => math.sqrt(math.pow(a.x - b.x, 2) + math.pow(a.y - b.y, 2));

String _describe(FeatureDto f, Map<String, String> sketchGeometry) {
  switch (f.type) {
    case 'sketch':
      final geometry = f.sketchId != null ? sketchGeometry[f.sketchId] ?? 'empty' : 'empty';
      return 'sketch (plane ${f.planeFeatureId != null ? 'existing:${f.planeFeatureId}' : 'fixed'}) - contains: '
          '$geometry';
    case 'extrude':
      return 'extrude ${_fmt(f.startDistance)}->${_fmt(f.endDistance)}mm (${f.extrudeType ?? '?'})${_fromSketch(f)}';
    case 'revolve':
      return 'revolve ${_fmt(f.angle)}° (${f.mode ?? '?'})${_fromSketch(f)}';
    case 'sweep':
      return 'sweep along ${f.pathRefs.length} path(s) (${f.mode ?? '?'})${_fromSketch(f)}';
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

/// Points an extrude/revolve/sweep description back at the Sketch entry
/// above so the model can connect its own boss/cut numbers to the real
/// profile that produced them, rather than only knowing "a sketch was
/// extruded" with no link to which one or what shape it was.
String _fromSketch(FeatureDto f) => f.sketchFeatureId != null ? ', from existing:${f.sketchFeatureId}' : '';
