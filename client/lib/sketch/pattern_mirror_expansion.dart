import 'dart:math' as math;

/// Sketcher-roadmap Phase 7 follow-up (on-device feedback: the green
/// closed-profile fill, the Part's own 3D-viewport sketch outline, and
/// Select-mode hit-testing all need to resolve a Pattern/Mirror instance's
/// own *derived* geometry, not just its live-preview ghosts): this module
/// is the client's own mirror of the backend's `Sketch.expand_pattern_and_
/// mirror_instances` id/point/welding scheme (`backend/app/sketch/
/// models.py`) - every rule here must stay in lockstep with it (same
/// deterministic ids, same "a transformed Point that lands back on its own
/// source position reuses that Point's id" welding fix, same mirrored-Arc
/// endpoint swap). Deliberately not tied to `SketchController`'s own
/// `SketchLineView`/`SketchCircleView`/`SketchArcView` or the API's
/// `LineDto`/`CircleDto`/`ArcDto` - a plain, minimal shape so this one
/// implementation can be shared by both `SketchController` (live editing)
/// and `part_screen.dart` (showing a Sketch's outline in the 3D viewport
/// without editing it).

enum PatternMirrorEntityKind { line, circle, arc, ellipse, ellipseArc }

class PatternMirrorSourceEntity {
  final String id;
  final PatternMirrorEntityKind kind;
  final bool construction;

  /// Circle/Arc/Ellipse/EllipseArc only - null for a Line.
  final String? centerPointId;

  /// Line: start point. Circle: radius (edge) point. Arc/EllipseArc: start
  /// point. Unused (empty) for an Ellipse - see [majorPointId] instead.
  final String startPointId;

  /// Line: end point. Arc/EllipseArc: end point. Unused (empty) for a
  /// Circle or Ellipse.
  final String endPointId;

  /// Ellipse/EllipseArc only - the major-axis point.
  final String? majorPointId;

  /// Ellipse/EllipseArc only - the minor-axis point.
  final String? minorPointId;

  /// Ellipse only - the two negative/opposite axis-tip points (see the
  /// backend's `Ellipse` docstring). Null for EllipseArc, which has no
  /// negative tips of its own.
  final String? majorPointNegId;
  final String? minorPointNegId;

  const PatternMirrorSourceEntity({
    required this.id,
    required this.kind,
    required this.construction,
    this.centerPointId,
    required this.startPointId,
    this.endPointId = '',
    this.majorPointId,
    this.minorPointId,
    this.majorPointNegId,
    this.minorPointNegId,
  });
}

/// Mirrors the backend's `SketchPatternDirection` - exactly one of
/// [lineId]/[fixedAxis] ("x"/"y") is ever set.
class PatternMirrorDirection {
  final String? lineId;
  final String? fixedAxis;

  const PatternMirrorDirection({this.lineId, this.fixedAxis});
}

/// Mirrors the backend's `SketchPatternInstance` - see that class's own
/// docstring for the row-major (`index = i * count2 + j`) grid convention.
class PatternMirrorPatternInstance {
  final String id;
  final List<String> sourceEntityIds;
  final PatternMirrorDirection direction1;
  final int count1;
  final double spacing1;
  final bool reverse1;
  final PatternMirrorDirection? direction2;
  final int count2;
  final double spacing2;
  final bool reverse2;

  const PatternMirrorPatternInstance({
    required this.id,
    required this.sourceEntityIds,
    required this.direction1,
    required this.count1,
    required this.spacing1,
    this.reverse1 = false,
    this.direction2,
    this.count2 = 1,
    this.spacing2 = 0.0,
    this.reverse2 = false,
  });
}

/// Mirrors the backend's `SketchMirrorInstance`.
class PatternMirrorMirrorInstance {
  final String id;
  final List<String> sourceEntityIds;
  final String mirrorLineId;

  const PatternMirrorMirrorInstance({
    required this.id,
    required this.sourceEntityIds,
    required this.mirrorLineId,
  });
}

/// One derived (transient, synthetic-id) Line/Circle/Arc copy produced by
/// expanding a Pattern/Mirror instance - [ownerInstanceId] is what a
/// Select-mode hit/context-menu action needs to resolve "which whole
/// instance does this belong to" (see `SketchController`'s own selection
/// wiring); an individual derived entity is never independently
/// selectable/editable on its own, only its owning instance is.
class PatternMirrorExpandedEntity {
  final String id;
  final PatternMirrorEntityKind kind;
  final bool construction;
  final String ownerInstanceId;
  final bool isMirror;
  final String? centerPointId;
  final String startPointId;
  final String endPointId;

  /// Ellipse/EllipseArc only - the transformed major/minor-axis points.
  final String? majorPointId;
  final String? minorPointId;

  /// Ellipse only - the transformed negative/opposite axis-tip points.
  final String? majorPointNegId;
  final String? minorPointNegId;

  const PatternMirrorExpandedEntity({
    required this.id,
    required this.kind,
    required this.construction,
    required this.ownerInstanceId,
    required this.isMirror,
    this.centerPointId,
    required this.startPointId,
    required this.endPointId,
    this.majorPointId,
    this.minorPointId,
    this.majorPointNegId,
    this.minorPointNegId,
  });
}

class PatternMirrorExpansion {
  /// Every synthetic point id referenced by [entities] below, id -> (x, y)
  /// - a welded point (see this file's own doc comment) reuses its
  /// original real id here too, so a caller resolving an arbitrary point id
  /// (e.g. from a backend Profile's own `point_ids`) can check a real
  /// points map first and fall back to this one, uniformly.
  final Map<String, (double, double)> points;
  final List<PatternMirrorExpandedEntity> entities;

  const PatternMirrorExpansion({required this.points, required this.entities});

  static const empty = PatternMirrorExpansion(points: {}, entities: []);

  bool get isEmpty => entities.isEmpty;
}

/// Expands every one of [patternInstances]/[mirrorInstances] into derived
/// (synthetic-id) Line/Circle/Arc copies, resolved against [points]/
/// [entities] - the *current* real geometry, so associativity (a source
/// Point moving moves every derived copy with it) falls out for free by
/// simply calling this again with fresh input, never by caching.
///
/// A stale reference (a deleted source entity, a deleted/zero-length
/// direction or mirror Line) degrades that one instance/grid-cell to
/// nothing, never throws - matching the backend's own drift-tolerant
/// `expand_pattern_and_mirror_instances`.
PatternMirrorExpansion expandPatternAndMirrorInstances({
  required Map<String, (double, double)> points,
  required Map<String, PatternMirrorSourceEntity> entities,
  required Iterable<PatternMirrorPatternInstance> patternInstances,
  required Iterable<PatternMirrorMirrorInstance> mirrorInstances,
}) {
  if (patternInstances.isEmpty && mirrorInstances.isEmpty) return PatternMirrorExpansion.empty;

  final resultPoints = <String, (double, double)>{};
  final resultEntities = <PatternMirrorExpandedEntity>[];

  (double, double)? directionUnitVector(PatternMirrorDirection? direction) {
    if (direction == null) return null;
    final fixedAxis = direction.fixedAxis;
    if (fixedAxis != null) {
      return fixedAxis == 'x' ? (1.0, 0.0) : (0.0, 1.0);
    }
    final lineId = direction.lineId;
    if (lineId == null) return null;
    final line = entities[lineId];
    if (line == null || line.kind != PatternMirrorEntityKind.line) return null;
    final start = points[line.startPointId];
    final end = points[line.endPointId];
    if (start == null || end == null) return null;
    final dx = end.$1 - start.$1;
    final dy = end.$2 - start.$2;
    final length = math.sqrt(dx * dx + dy * dy);
    if (length == 0) return null;
    return (dx / length, dy / length);
  }

  void placeTransformed(
    PatternMirrorSourceEntity entity, {
    required String newIdPrefix,
    required String pointIdPrefix,
    required (double, double) Function(double, double) transform,
    required bool swapArcEndpoints,
    required String ownerInstanceId,
    required bool isMirror,
  }) {
    String? transformedPoint(String? originalPointId) {
      if (originalPointId == null) return null;
      final original = points[originalPointId];
      if (original == null) return null;
      final transformed = transform(original.$1, original.$2);
      // Welding fix, mirrored from the backend's own `_place_transformed_
      // entity` - a transformed Point landing back on its own source
      // position (always true for a Mirror instance's own axis-crossing
      // Points) reuses the original Point's id instead of minting a
      // synthetic one, so a mirrored half-profile's own real/derived
      // halves stay connected at their shared, invariant Points.
      if ((transformed.$1 - original.$1).abs() < 1e-9 && (transformed.$2 - original.$2).abs() < 1e-9) {
        return originalPointId;
      }
      final newId = '$pointIdPrefix$originalPointId';
      resultPoints.putIfAbsent(newId, () => transformed);
      return newId;
    }

    final newId = '$newIdPrefix${entity.id}';
    switch (entity.kind) {
      case PatternMirrorEntityKind.line:
        final start = transformedPoint(entity.startPointId);
        final end = transformedPoint(entity.endPointId);
        if (start == null || end == null) return;
        resultEntities.add(PatternMirrorExpandedEntity(
          id: newId,
          kind: PatternMirrorEntityKind.line,
          construction: entity.construction,
          ownerInstanceId: ownerInstanceId,
          isMirror: isMirror,
          startPointId: start,
          endPointId: end,
        ));
      case PatternMirrorEntityKind.circle:
        final center = transformedPoint(entity.centerPointId);
        final radiusPoint = transformedPoint(entity.startPointId);
        if (center == null || radiusPoint == null) return;
        resultEntities.add(PatternMirrorExpandedEntity(
          id: newId,
          kind: PatternMirrorEntityKind.circle,
          construction: entity.construction,
          ownerInstanceId: ownerInstanceId,
          isMirror: isMirror,
          centerPointId: center,
          startPointId: radiusPoint,
          endPointId: '',
        ));
      case PatternMirrorEntityKind.arc:
        final startSourceId = swapArcEndpoints ? entity.endPointId : entity.startPointId;
        final endSourceId = swapArcEndpoints ? entity.startPointId : entity.endPointId;
        final center = transformedPoint(entity.centerPointId);
        final start = transformedPoint(startSourceId);
        final end = transformedPoint(endSourceId);
        if (center == null || start == null || end == null) return;
        resultEntities.add(PatternMirrorExpandedEntity(
          id: newId,
          kind: PatternMirrorEntityKind.arc,
          construction: entity.construction,
          ownerInstanceId: ownerInstanceId,
          isMirror: isMirror,
          centerPointId: center,
          startPointId: start,
          endPointId: end,
        ));
      case PatternMirrorEntityKind.ellipse:
        // Every one of the 5 defining Points is transformed directly and
        // independently - no offset-curve math needed (a translated or
        // reflected ellipse is still an ellipse), and no special re-
        // derivation of the negative axis tips either, since translation
        // and reflection are both affine maps that preserve midpoint
        // relationships, so the AtMidpoint symmetry between a positive tip
        // and its negative counterpart survives automatically. Mirrors the
        // backend's `_place_transformed_entity` Ellipse branch.
        final center = transformedPoint(entity.centerPointId);
        final major = transformedPoint(entity.majorPointId);
        final majorNeg = transformedPoint(entity.majorPointNegId);
        final minor = transformedPoint(entity.minorPointId);
        final minorNeg = transformedPoint(entity.minorPointNegId);
        if (center == null || major == null || majorNeg == null || minor == null || minorNeg == null) return;
        resultEntities.add(PatternMirrorExpandedEntity(
          id: newId,
          kind: PatternMirrorEntityKind.ellipse,
          construction: entity.construction,
          ownerInstanceId: ownerInstanceId,
          isMirror: isMirror,
          centerPointId: center,
          startPointId: '',
          endPointId: '',
          majorPointId: major,
          minorPointId: minor,
          majorPointNegId: majorNeg,
          minorPointNegId: minorNeg,
        ));
      case PatternMirrorEntityKind.ellipseArc:
        // Same swap_arc_endpoints reasoning as the Arc branch above -
        // Mirror's reflection has negative determinant, reversing apparent
        // winding for any directional curve, circle-arc or ellipse-arc
        // alike - and `rotation()` is always recomputed from the current
        // major point position, so transforming it directly is enough.
        final startSourceId = swapArcEndpoints ? entity.endPointId : entity.startPointId;
        final endSourceId = swapArcEndpoints ? entity.startPointId : entity.endPointId;
        final center = transformedPoint(entity.centerPointId);
        final major = transformedPoint(entity.majorPointId);
        final minor = transformedPoint(entity.minorPointId);
        final start = transformedPoint(startSourceId);
        final end = transformedPoint(endSourceId);
        if (center == null || major == null || minor == null || start == null || end == null) return;
        resultEntities.add(PatternMirrorExpandedEntity(
          id: newId,
          kind: PatternMirrorEntityKind.ellipseArc,
          construction: entity.construction,
          ownerInstanceId: ownerInstanceId,
          isMirror: isMirror,
          centerPointId: center,
          startPointId: start,
          endPointId: end,
          majorPointId: major,
          minorPointId: minor,
        ));
    }
  }

  for (final instance in patternInstances) {
    final unit1 = directionUnitVector(instance.direction1);
    if (unit1 == null) continue;
    var dx1 = unit1.$1;
    var dy1 = unit1.$2;
    if (instance.reverse1) {
      dx1 = -dx1;
      dy1 = -dy1;
    }
    var dx2 = 0.0;
    var dy2 = 0.0;
    if (instance.count2 > 1) {
      final unit2 = directionUnitVector(instance.direction2);
      if (unit2 == null) continue;
      dx2 = unit2.$1;
      dy2 = unit2.$2;
      if (instance.reverse2) {
        dx2 = -dx2;
        dy2 = -dy2;
      }
    }
    for (var i = 0; i < instance.count1; i++) {
      for (var j = 0; j < instance.count2; j++) {
        final index = i * instance.count2 + j;
        if (index == 0) continue; // The untouched seed - never recreated.
        final offsetX = dx1 * instance.spacing1 * i + dx2 * instance.spacing2 * j;
        final offsetY = dy1 * instance.spacing1 * i + dy2 * instance.spacing2 * j;
        for (final entityId in instance.sourceEntityIds) {
          final entity = entities[entityId];
          if (entity == null) continue;
          placeTransformed(
            entity,
            newIdPrefix: '${instance.id}#$index#',
            pointIdPrefix: '${instance.id}#p$index#',
            transform: (x, y) => (x + offsetX, y + offsetY),
            swapArcEndpoints: false,
            ownerInstanceId: instance.id,
            isMirror: false,
          );
        }
      }
    }
  }

  for (final instance in mirrorInstances) {
    final mirrorLine = entities[instance.mirrorLineId];
    if (mirrorLine == null || mirrorLine.kind != PatternMirrorEntityKind.line) continue;
    final a = points[mirrorLine.startPointId];
    final b = points[mirrorLine.endPointId];
    if (a == null || b == null) continue;
    final abx = b.$1 - a.$1;
    final aby = b.$2 - a.$2;
    final abLenSq = abx * abx + aby * aby;
    if (abLenSq == 0) continue;

    (double, double) reflect(double x, double y) {
      final apx = x - a.$1;
      final apy = y - a.$2;
      final t = (apx * abx + apy * aby) / abLenSq;
      final footX = a.$1 + t * abx;
      final footY = a.$2 + t * aby;
      return (2 * footX - x, 2 * footY - y);
    }

    for (final entityId in instance.sourceEntityIds) {
      final entity = entities[entityId];
      if (entity == null) continue;
      placeTransformed(
        entity,
        newIdPrefix: '${instance.id}#m#',
        pointIdPrefix: '${instance.id}#pm#',
        transform: reflect,
        swapArcEndpoints: true,
        ownerInstanceId: instance.id,
        isMirror: true,
      );
    }
  }

  return PatternMirrorExpansion(points: resultPoints, entities: resultEntities);
}
