import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import '../assembly/occurrence_visibility.dart';
import 'mesh_geometry.dart';
import 'render_mode.dart';

/// Pure decision helpers behind `PartViewport`'s placed-instance (assembly
/// lens) rendering, split out so they can be unit-tested without a GPU scene.

/// Whether a placed-instance Body should be drawn at all. The backend's
/// `source: "placeholder"` box (a stand-in for "this Part has no geometry
/// yet") is never real geometry in an assembly scene - it used to show up as
/// a stray 10x10x10 cube at the origin.
bool isRenderableAssemblyBody(BodyMeshDto body) => body.source != 'placeholder';

/// Whether placed instances get filled faces: the same gate the root/focused
/// Part's own Bodies use (`_syncMeshNode`) - none in wireframe, none while
/// Bodies are hidden. Edges are drawn separately (see `showsEdges`).
bool assemblyInstanceFacesVisible(ViewportRenderMode mode, {required bool bodiesHidden}) =>
    mode.showsFilledFaces && !bodiesHidden;

/// True when any occurrence in [occurrenceKeys] (joined `occurrencePath`s)
/// has a different world transform in [next] than in [previous], or appears
/// in only one of them. Compared per instance by value, not by list
/// identity - `PartScreen` hands over a freshly built list on every rebuild.
bool occurrenceInstanceTransformsDiffer(
  Set<String> occurrenceKeys,
  List<AssemblyOccurrenceInstanceDto> previous,
  List<AssemblyOccurrenceInstanceDto> next,
) {
  RigidTransformDto? transformOf(List<AssemblyOccurrenceInstanceDto> instances, String key) {
    for (final instance in instances) {
      if (instance.occurrencePath.join('/') == key) return instance.worldTransform;
    }
    return null;
  }

  for (final key in occurrenceKeys) {
    if (transformOf(next, key) != transformOf(previous, key)) return true;
  }
  return false;
}

/// One occurrence a mate preview moves: its stored pose ([previous]) and the pose the preview solved ([next]), both local to
/// the focused part (the frame `Occurrence.transform` is in). `PartViewport.matePreviewMembers`.
class MatePreviewMember {
  final String occurrenceId;
  final RigidTransformDto previous;
  final RigidTransformDto next;

  const MatePreviewMember({required this.occurrenceId, required this.previous, required this.next});
}

/// A ghost placement: render [instance]'s geometry at [world] instead of its own world transform.
class MatePreviewGhost {
  final AssemblyOccurrenceInstanceDto instance;
  final vm.Matrix4 world;

  const MatePreviewGhost(this.instance, this.world);
}

/// Where the mate preview draws its ghosts: every visible placed instance that belongs to a previewed occurrence - the
/// occurrence's own instance and, for a sub-assembly, every instance nested inside it (a sub-assembly part has no bodies of
/// its own, its leaf bodies are the instances below it). Each is moved by the occurrence's world-space change,
/// `T_ghost = F * T_new * T_old^-1 * F^-1 * instanceWorld`, with `F` the focused part's world placement
/// ([focusWorld], identity while nothing is focused) because `previous`/`next` are local to it.
List<MatePreviewGhost> matePreviewGhosts({
  required List<AssemblyOccurrenceInstanceDto> instances,
  required List<MatePreviewMember> members,
  List<String> focusedPath = const [],
  vm.Matrix4? focusWorld,
}) {
  final focus = focusWorld ?? vm.Matrix4.identity();
  final focusInverse = focus.clone()..invert();
  final ghosts = <MatePreviewGhost>[];
  for (final member in members) {
    final previous = matrix4FromRigidTransform(member.previous);
    final next = matrix4FromRigidTransform(member.next);
    final previousInverse = previous.clone()..invert();
    final worldDelta = focus * next * previousInverse * focusInverse;
    for (final instance in instances) {
      final path = instance.occurrencePath;
      if (instance.hidden || path.length <= focusedPath.length) continue;
      if (!pathEquals(path.sublist(0, focusedPath.length), focusedPath)) continue;
      if (path[focusedPath.length] != member.occurrenceId) continue;
      ghosts.add(MatePreviewGhost(instance, worldDelta * matrix4FromRigidTransform(instance.worldTransform)));
    }
  }
  return ghosts;
}
