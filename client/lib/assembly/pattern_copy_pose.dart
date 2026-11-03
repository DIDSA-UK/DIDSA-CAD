import 'dart:math' as math;

import '../api/document_api_client.dart';
import '../motion/mate_motion_bridge.dart' show dtoOfPose, poseOfDto;
import '../motion/se3.dart';
import 'occurrence_visibility.dart' show pathEquals;

// Everything here is plain `double` math (se3.dart `Pose` / `Mat3`), not `vector_math`'s float32 matrices: the golden test holds it to the
// backend's numbers at 1e-9, and a float32 matrix is only good to ~6e-5 mm at 1000 mm.

/// `parent ∘ child`: apply [child] first, then [parent] (the backend's `compose`).
Pose _compose(Pose parent, Pose child) {
  final rt = parent.r.mulVec(child.t);
  return Pose(<double>[rt[0] + parent.t[0], rt[1] + parent.t[1], rt[2] + parent.t[2]], parent.r * child.r);
}

Pose _inverse(Pose p) {
  final rt = p.r.transposed;
  final t = rt.mulVec(p.t);
  return Pose(<double>[-t[0], -t[1], -t[2]], rt);
}

/// The client mirror of the backend's `assembly.pattern_copy_pose` (and `pattern_step`): the pose of copy [index] of [pattern] for a
/// source at [source], both in the pattern's own frame (the focused Part's: a source occurrence's LOCAL transform). Linear
/// `index = i * count2 + j`; Circular is the 1-based angular step, and with `orientWithRotation == false` it keeps the source's rotation.
/// Does not check that the index is live: [livePatternIndices] says which are.
///
/// Checked against the backend's own numbers by `test/pattern_copy_pose_test.dart` (a committed golden fixture generated from the
/// backend: `tools/motion_vectors/pattern_copy_pose_vectors.py`).
RigidTransformDto patternCopyPose(ComponentPatternDto pattern, RigidTransformDto source, int index) {
  final copy = _copyPose(pattern, poseOfDto(source), index);
  if (pattern.patternType == 'linear' || pattern.orientWithRotation) return dtoOfPose(copy);
  // keeps the source's rotation: hand back its own axis / angle, not a re-derived pair
  return RigidTransformDto(
    translation: copy.t,
    rotationAxis: source.rotationAxis,
    rotationAngleDegrees: source.rotationAngleDegrees,
  );
}

Pose _copyPose(ComponentPatternDto pattern, Pose source, int index) {
  final (step, keepRotation) = _patternStep(pattern, index);
  final composed = _compose(step, source);
  return keepRotation ? Pose(composed.t, source.r) : composed;
}

/// The indices of [pattern]'s live copies: every derived index (the seed, 0, is the source itself) that is not skipped. Backend
/// `_live_pattern_indices`.
List<int> livePatternIndices(ComponentPatternDto pattern) {
  final skipped = pattern.skipIndices.toSet();
  final total = pattern.patternType == 'linear'
      ? math.max(pattern.count, 1) * math.max(pattern.count2, 1)
      : math.max(pattern.countAngular, 1);
  return [for (var i = 1; i < total; i++) if (!skipped.contains(i)) i];
}

Pose _translation(List<double> t) => Pose(t, Mat3.identity());

List<double> _linearStep(List<double> direction, double distance) {
  final n = norm3(direction);
  if (n < 1e-6) return <double>[0, 0, 0]; // a degenerate direction is refused by the backend before it is ever stored
  return <double>[direction[0] / n * distance, direction[1] / n * distance, direction[2] / n * distance];
}

/// `(step, keepRotation)` of copy [index]: the copy of a source at `(R, t)` is at `step ∘ (R, t)`, with `R` itself kept when [keepRotation].
(Pose, bool) _patternStep(ComponentPatternDto p, int index) {
  if (p.patternType == 'linear') {
    final count2 = math.max(p.count2, 1);
    final i = index ~/ count2;
    final j = index % count2;
    final sign1 = p.reverse ? -1.0 : 1.0;
    final sign2 = p.reverse2 ? -1.0 : 1.0;
    var t = _linearStep(p.direction, p.spacing * i * sign1);
    if (count2 > 1) {
      final t2 = _linearStep(p.direction2, p.spacing2 * j * sign2);
      t = <double>[t[0] + t2[0], t[1] + t2[1], t[2] + t2[2]];
    }
    return (_translation(t), false);
  }
  final count = math.max(p.countAngular, 1);
  final axis = p.axis;
  final origin = axis == null ? <double>[0, 0, 0] : axis.origin;
  final direction = axis == null ? <double>[0, 0, 1] : axis.direction;
  final angle = p.angleTotal / count * index * (p.reverseAngular ? -1.0 : 1.0);
  // `T(origin) R(axis, angle) T(-origin)`: the rotation about the line through `origin`; its translation term is `origin - R origin`
  final r = rotAxisAngle(direction, angle);
  final ro = r.mulVec(origin);
  return (Pose(<double>[origin[0] - ro[0], origin[1] - ro[1], origin[2] - ro[2]], r), !p.orientWithRotation);
}

/// Live drag overlay for pattern copies: [liveWorld] holds the WORLD poses of the occurrences (direct children of the focused Part, by id) a
/// drag is currently moving - the grabbed one and its followers. For each of them that is the source of a non-suppressed pattern in
/// [patterns] (the focused Part's), every live copy instance `[...focusPath, 'X#pattern:P:i']` is placed at `parentWorld ∘ patternCopyPose(P,
/// local(X), i)` and everything nested under a copy (`.../X#pattern:P:i/inner`) moves by the same delta (`newCopyWorld ∘ oldCopyWorld⁻¹ ∘ world`).
/// [parentWorld] is the focused Part's own placed transform (`null` at the root). [instances] already carry the exact-path overrides of the
/// sources themselves; anything this function does not touch passes through unchanged (same order, same objects).
///
/// The backend stays the authority: at the end of the drag the commit and the mesh refetch put every copy where the server says.
List<AssemblyOccurrenceInstanceDto> followPatternCopies(
  List<AssemblyOccurrenceInstanceDto> instances, {
  required List<String> focusPath,
  required List<ComponentPatternDto> patterns,
  required Map<String, RigidTransformDto> liveWorld,
  RigidTransformDto? parentWorld,
}) {
  if (liveWorld.isEmpty || patterns.isEmpty) return instances;
  final parent = parentWorld == null ? null : poseOfDto(parentWorld);
  Pose toWorld(Pose local) => parent == null ? local : _compose(parent, local);
  Pose toLocal(Pose world) => parent == null ? world : _compose(_inverse(parent), world);

  // path -> replacement world transform
  final replaced = <String, Pose>{};
  final result = List<AssemblyOccurrenceInstanceDto>.of(instances);
  String key(List<String> path) => path.join('\u0000');

  for (final pattern in patterns) {
    if (pattern.suppressed) continue;
    final indices = livePatternIndices(pattern);
    for (final sourceId in pattern.sourceOccurrenceIds) {
      final live = liveWorld[sourceId];
      if (live == null) continue;
      final sourceLocal = toLocal(poseOfDto(live));
      for (final index in indices) {
        final copyPath = [...focusPath, '$sourceId#pattern:${pattern.id}:$index'];
        AssemblyOccurrenceInstanceDto? oldCopy;
        for (final instance in instances) {
          if (pathEquals(instance.occurrencePath, copyPath)) oldCopy = instance;
        }
        final newCopyWorld = toWorld(_copyPose(pattern, sourceLocal, index));
        if (oldCopy != null) replaced[key(copyPath)] = newCopyWorld;
        // anything nested under the copy moves by the same delta
        if (oldCopy == null) continue;
        final oldCopyWorld = poseOfDto(oldCopy.worldTransform);
        for (final instance in instances) {
          final path = instance.occurrencePath;
          if (path.length <= copyPath.length || !pathEquals(path.sublist(0, copyPath.length), copyPath)) continue;
          replaced[key(path)] =
              _compose(newCopyWorld, _compose(_inverse(oldCopyWorld), poseOfDto(instance.worldTransform)));
        }
      }
    }
  }
  if (replaced.isEmpty) return instances;
  for (var i = 0; i < result.length; i++) {
    final world = replaced[key(result[i].occurrencePath)];
    if (world == null) continue;
    final instance = result[i];
    result[i] = AssemblyOccurrenceInstanceDto(
      occurrencePath: instance.occurrencePath,
      partId: instance.partId,
      worldTransform: dtoOfPose(world),
      hidden: instance.hidden,
      color: instance.color,
      appearance: instance.appearance,
      faceAppearances: instance.faceAppearances,
    );
  }
  return result;
}
