import '../api/sketch_api_client.dart';

/// Point Merge (docs/point-merge-and-vr-sketcher-plan.md, M2): the client's copy of the backend's `merge_keep_order` (`app/sketch/point_merge.py`),
/// so the Point that will survive a Merge can be ringed before the user taps it. The server decides in the end (it also knows which Points a Part
/// feature references, which a client does not); this is the same rule on what the client holds.

/// Every Point id [constraint] holds, the client-side mirror of the backend's `Constraint.point_ids()`. A line-pair constraint holds its lines' ends,
/// resolved through [lineEnds] (line id -> its start and end Point ids).
Set<String> constraintPointIds(ConstraintDto constraint, Map<String, (String, String)> lineEnds) {
  Set<String> ends(String lineId) {
    final pair = lineEnds[lineId];
    return pair == null ? <String>{} : {pair.$1, pair.$2};
  }

  return switch (constraint) {
    DistanceConstraintDto c => {c.pointAId, c.pointBId},
    VerticalConstraintDto c => {c.pointAId, c.pointBId},
    HorizontalConstraintDto c => {c.pointAId, c.pointBId},
    CoincidentConstraintDto c => {c.pointAId, c.pointBId},
    ConcentricConstraintDto c => {c.center1PointId, c.center2PointId},
    AngleConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    ParallelConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    PerpendicularConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    EqualLengthConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    CollinearConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    LineDistanceConstraintDto c => {...ends(c.line1Id), ...ends(c.line2Id)},
    PointLineDistanceConstraintDto c => {c.pointId, ...ends(c.lineId)},
    AtMidpointConstraintDto c => {c.pointId, ...ends(c.lineId)},
    PointOnLineConstraintDto c => {c.pointId, ...ends(c.lineId)},
    PointOnCircleConstraintDto c => {c.pointId, c.centerPointId, c.radiusPointId},
    PointOnEllipseConstraintDto c => {c.pointId, c.centerPointId, c.majorPointId, c.minorPointId},
    TangentConstraintDto c => {c.centerPointId, c.radiusPointId, ...ends(c.lineId)},
    CurveTangentConstraintDto c => {c.center1PointId, c.center2PointId, c.sharedPointId},
    EqualRadiusConstraintDto c => {c.center1PointId, c.radius1PointId, c.center2PointId, c.radius2PointId},
    FixedConstraintDto c => c.pointIds.toSet(),
    SplineTangentConstraintDto c => {
        c.segmentAP0,
        c.segmentAP1,
        c.segmentAP2,
        c.segmentAP3,
        c.segmentBP0,
        c.segmentBP1,
        c.segmentBP2,
        c.segmentBP3,
      },
    _ => <String>{},
  };
}

/// [pointIds] (selection order) ordered by who is kept: an anchored Point first ([anchoredIds]: pinned by a Fix or an external reference), then the one with
/// the most constraints on it, then the one selected first. The first entry is the Point that survives. A constraint is not counted when it is a provisional
/// dimension (the solver skips it) or a Coincident between two of the selected Points (the merge removes it). Ties keep selection order (a stable sort).
List<String> mergeKeepOrder({
  required List<String> pointIds,
  required Set<String> anchoredIds,
  required Iterable<ConstraintDto> constraints,
  required Map<String, (String, String)> lineEnds,
}) {
  final ids = pointIds.toSet().toList();
  final selected = ids.toSet();
  final counts = {for (final id in ids) id: 0};
  for (final constraint in constraints) {
    if (constraint is DistanceConstraintDto && constraint.provisional) continue;
    if (constraint is CoincidentConstraintDto && selected.contains(constraint.pointAId) && selected.contains(constraint.pointBId)) continue;
    for (final id in constraintPointIds(constraint, lineEnds)) {
      if (counts.containsKey(id)) counts[id] = counts[id]! + 1;
    }
  }
  final position = {for (var i = 0; i < ids.length; i++) ids[i]: i};
  final ordered = [...ids]..sort((a, b) {
      final anchoredA = anchoredIds.contains(a) ? 0 : 1;
      final anchoredB = anchoredIds.contains(b) ? 0 : 1;
      if (anchoredA != anchoredB) return anchoredA - anchoredB;
      if (counts[a] != counts[b]) return counts[b]! - counts[a]!;
      return position[a]! - position[b]!;
    });
  return ordered;
}
