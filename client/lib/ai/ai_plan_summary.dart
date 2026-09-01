import 'dart:math';

import 'ai_plan.dart';

/// AI Modelling workstream 2's Review & Generate summary
/// (`02-scoping-conversation.md`'s "Plan-review handoff" section) - a
/// human-readable line per plan step, derived from the plan data rather
/// than raw JSON. Deliberately shows **literal step values**
/// ("Extrude 0->10mm", not just "Extrude") rather than only step *types* -
/// a hard requirement carried over from `03-structured-plan-schema.md`'s
/// "Spike findings" section: a real, reproduced LLM hallucination silently
/// changed a stated `end_distance` from 5mm to 40mm past every structural/
/// referential check workstream 5's validator runs, and a human skimming
/// real numbers next to what they just typed is the one layer that would
/// have caught it before it touched a real Part.
///
/// `sketch_point` steps are skipped in the returned list - they carry no
/// shape of their own, only inputs other steps (rectangles, lines, circles)
/// resolve back to for their own literal values below.
List<String> summarizeAiPlan(AiGenerationPlan plan) {
  return plan.steps.where((s) => s is! AiSketchPointStep).map((s) => _summarizeStep(plan, s)).toList();
}

typedef _Point = ({double x, double y});

_Point? _pointXY(AiGenerationPlan plan, String? localId) {
  if (localId == null) return null;
  final step = plan.stepById(localId);
  return step is AiSketchPointStep ? (x: step.x, y: step.y) : null;
}

double _distance(_Point a, _Point b) => sqrt(pow(b.x - a.x, 2) + pow(b.y - a.y, 2));

String _fmt(double v) {
  if (v == v.roundToDouble()) return v.toStringAsFixed(0);
  var s = v.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  s = s.replaceFirst(RegExp(r'\.$'), '');
  return s;
}

String _fmtPoint(_Point p) => '(${_fmt(p.x)},${_fmt(p.y)})';

String _summarizeStep(AiGenerationPlan plan, AiPlanStep step) {
  switch (step) {
    case AiSketchStep():
      if (step.plane != null) return 'New Sketch on ${step.plane!.wireValue}';
      if (step.planeFeatureId != null) return 'New Sketch on Plane #${step.planeFeatureId}';
      return 'New Sketch';

    case AiSketchPointStep():
      return 'Point ${_fmtPoint((x: step.x, y: step.y))}';

    case AiSketchLineStep():
      final start = _pointXY(plan, step.startPointId);
      final end = _pointXY(plan, step.endPointId);
      if (start != null && end != null) return 'Line ${_fmtPoint(start)} → ${_fmtPoint(end)}';
      if (step.length != null && step.angle != null) return 'Line ${_fmt(step.length!)}mm @ ${_fmt(step.angle!)}°';
      return 'Line';

    case AiSketchCircleStep():
      final center = _pointXY(plan, step.centerPointId);
      final radiusPoint = _pointXY(plan, step.radiusPointId);
      final radius = step.radius ?? (center != null && radiusPoint != null ? _distance(center, radiusPoint) : null);
      final radiusText = radius == null ? '' : ' r=${_fmt(radius)}mm';
      return center == null ? 'Circle$radiusText' : 'Circle$radiusText at ${_fmtPoint(center)}';

    case AiSketchArcStep():
      final center = _pointXY(plan, step.centerPointId);
      final start = _pointXY(plan, step.startPointId);
      final radius = center != null && start != null ? _distance(center, start) : null;
      final radiusText = radius == null ? '' : ' r=${_fmt(radius)}mm';
      final at = center == null ? '' : ' at ${_fmtPoint(center)}';
      final endText = step.endAngle == null ? '' : ' → ${_fmt(step.endAngle!)}°';
      return 'Arc$radiusText$at$endText';

    case AiSketchEllipseStep():
      final center = _pointXY(plan, step.centerPointId);
      final majorPoint = _pointXY(plan, step.majorPointId);
      final majorRadius = step.majorRadius ?? (center != null && majorPoint != null ? _distance(center, majorPoint) : null);
      final majorText = majorRadius == null ? '?' : _fmt(majorRadius);
      return 'Ellipse major=${majorText}mm minor=${_fmt(step.minorRadius)}mm';

    case AiSketchPolygonStep():
      final center = _pointXY(plan, step.centerPointId);
      return center == null ? '${step.sides}-sided Polygon' : '${step.sides}-sided Polygon at ${_fmtPoint(center)}';

    case AiSketchSlotStep():
      final c1 = _pointXY(plan, step.center1PointId);
      final c2 = _pointXY(plan, step.center2PointId);
      if (c1 != null && c2 != null) return 'Slot r=${_fmt(step.radius)}mm between ${_fmtPoint(c1)} and ${_fmtPoint(c2)}';
      return 'Slot r=${_fmt(step.radius)}mm';

    case AiSketchRectangleStep():
      final corners = step.cornerPointIds.map((id) => _pointXY(plan, id)).whereType<_Point>().toList();
      if (corners.length == step.cornerPointIds.length && corners.isNotEmpty) {
        final xs = corners.map((p) => p.x);
        final ys = corners.map((p) => p.y);
        final width = xs.reduce(max) - xs.reduce(min);
        final height = ys.reduce(max) - ys.reduce(min);
        return 'Rectangle ${_fmt(width)}×${_fmt(height)}mm';
      }
      return 'Rectangle (${step.cornerPointIds.length} corners)';

    case AiExtrudeStep():
      final cutSuffix = step.extrudeType == AiExtrudeType.cut ? _cutTargetSuffix(step.targetBodyIds) : '';
      return 'Extrude ${_fmt(step.startDistance)}→${_fmt(step.endDistance)}mm (${step.extrudeType.wireValue}$cutSuffix)';

    case AiRevolveStep():
      final cutSuffix = step.mode == AiRevolveMode.cut ? _cutTargetSuffix(step.targetBodyIds) : '';
      return 'Revolve ${_fmt(step.angle)}° (${step.mode.wireValue}$cutSuffix)';

    case AiSweepStep():
      final cutSuffix = step.mode == AiSweepMode.cut ? _cutTargetSuffix(step.targetBodyIds) : '';
      return 'Sweep along ${step.pathRefs.length} path(s) (${step.mode.wireValue}$cutSuffix)';

    case AiFilletStep():
      return 'Fillet ${_selectorLabel(step.edges)} @${_fmt(step.radius)}mm';

    case AiChamferStep():
      return 'Chamfer ${_selectorLabel(step.edges)} @${_fmt(step.distance)}mm';

    case AiPatternStep():
      if (step.patternType == AiPatternType.circular) {
        return 'Pattern (circular) ${step.countAngular}× over ${_fmt(step.angleTotal)}°';
      }
      return 'Pattern (rectangular) ${step.count1}×${step.count2}, spacing ${_fmt(step.spacing1)}/${_fmt(step.spacing2)}mm';

    case AiMirrorStep():
      return 'Mirror across ${_mirrorPlaneLabel(step.mirrorPlane)}';

    case AiCreatePlaneStep():
      return 'Create Plane (${step.planeType.wireValue})';

    case AiGearRequestStep():
      if (step.parameters.isEmpty) return 'Gear request';
      final params = step.parameters.entries.map((e) => '${e.key}=${e.value}').join(', ');
      return 'Gear request: $params';
  }
}

/// Real finding: `target_body_ids` is required (validation fails with
/// `invalid_step_payload`) whenever a cut-mode step's list is empty, but
/// this was previously invisible in the plan panel - a "cut" step and a
/// well-formed one read identically until Generate/preflight ran. Surfacing
/// it here, including the empty case, lets a human catch the gap by eye
/// before spending a validation round-trip on it.
String _cutTargetSuffix(List<String> targetBodyIds) {
  if (targetBodyIds.isEmpty) return ', into ⚠ no body specified';
  return ', into ${targetBodyIds.join(', ')}';
}

String _selectorLabel(AiEdgeSelector edges) {
  final base = edges.selector.wireValue.replaceAll('_', ' ');
  return edges.direction == null ? base : '$base (${edges.direction!.wireValue})';
}

String _mirrorPlaneLabel(AiMirrorPlaneStep plane) {
  if (plane.fixedPlane != null) return plane.fixedPlane!.wireValue;
  if (plane.planeFeatureId != null) return 'Plane #${plane.planeFeatureId}';
  return 'plane';
}
