import '../api/document_api_client.dart';
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
