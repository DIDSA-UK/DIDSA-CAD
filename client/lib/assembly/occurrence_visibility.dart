import '../api/document_api_client.dart';

/// Assembly support Phase 4 (`docs/assembly-scope.md` §3): folds
/// [PartScreen]'s two purely client-side Hide/Isolate overlays into each
/// [OccurrenceDto]'s own [OccurrenceDto.hidden] field, without ever
/// mutating [occurrences] itself - the one place this combination happens,
/// so [AssemblyTreePanel] (which only ever reads [OccurrenceDto.hidden]
/// directly) and the 3D viewport (via `PartScreen._refreshAssemblyMesh`'s
/// own instance-hidden field) never need their own copy of this logic.
///
/// No backend mutation endpoint exists for Occurrences at all
/// (`docs/assembly-scope.md` §2e's own documented gap) - [hiddenOccurrenceIds]/
/// [isolatedOccurrenceId] are pure session state a real "Hide"/"Isolate"
/// action can only ever OR onto whatever the backend already reports, never
/// override it: an Occurrence whose own [OccurrenceDto.hidden] arrived from
/// the backend as `true` (e.g. loaded from a file saved with it hidden)
/// stays hidden regardless of what's in either set - there is nothing here
/// that could ever un-hide it, a real (and honestly documented, not
/// papered-over) limitation of shipping Hide/Show with no mutation endpoint
/// to persist against.
///
/// [isolatedOccurrenceId], when non-null, hides every *other* Occurrence -
/// at most one Occurrence stays isolated at a time, unlike
/// [hiddenOccurrenceIds] which has no such cap.
List<OccurrenceDto> applyOccurrenceVisibilityOverrides(
  List<OccurrenceDto> occurrences, {
  required Set<String> hiddenOccurrenceIds,
  required String? isolatedOccurrenceId,
}) {
  return [
    for (final occurrence in occurrences)
      OccurrenceDto(
        id: occurrence.id,
        externalRef: occurrence.externalRef,
        resolvedPartId: occurrence.resolvedPartId,
        nameOverride: occurrence.nameOverride,
        transform: occurrence.transform,
        suppressed: occurrence.suppressed,
        hidden: occurrence.hidden ||
            hiddenOccurrenceIds.contains(occurrence.id) ||
            (isolatedOccurrenceId != null && occurrence.id != isolatedOccurrenceId),
      ),
  ];
}

/// [applyOccurrenceVisibilityOverrides]'s sibling for Phase 2's own placed-
/// instance list ([AssemblyOccurrenceInstanceDto], `AssemblyMeshDto.instances`
/// - what actually feeds the 3D viewport, `PartViewport.assemblyInstances`)
/// rather than the Assembly tree's own [OccurrenceDto] list - needed
/// because the two are keyed differently: an [OccurrenceDto] is only ever
/// shown at *one* nesting level (whichever Part [AssemblyFocusStack.current]
/// currently is), so its own bare `id` is enough to match a
/// [hiddenOccurrenceIds]/[isolatedOccurrenceId] entry directly, but a
/// placed instance's [AssemblyOccurrenceInstanceDto.occurrencePath] is the
/// *whole chain* of Occurrence ids from the true root down to it - Hide/
/// Isolate toggled on an Occurrence at any level must hide every instance
/// nested underneath it too (the standard "hiding an assembly hides its
/// own contents" CAD convention), which checking only the path's *last*
/// segment would miss entirely.
///
/// [isolatedOccurrenceId] keeps visible every instance whose own path
/// contains it (the isolated Occurrence's own placed instance, and
/// anything nested inside it), same "isolating a subassembly still shows
/// its own contents" convention - not just an exact path match.
List<AssemblyOccurrenceInstanceDto> applyInstanceVisibilityOverrides(
  List<AssemblyOccurrenceInstanceDto> instances, {
  required Set<String> hiddenOccurrenceIds,
  required String? isolatedOccurrenceId,
}) {
  return [
    for (final instance in instances)
      AssemblyOccurrenceInstanceDto(
        occurrencePath: instance.occurrencePath,
        partId: instance.partId,
        worldTransform: instance.worldTransform,
        hidden: instance.hidden ||
            instance.occurrencePath.any(hiddenOccurrenceIds.contains) ||
            (isolatedOccurrenceId != null && !instance.occurrencePath.contains(isolatedOccurrenceId)),
      ),
  ];
}

/// Phase 4 fix (`docs/assembly-scope.md` §5 appendix item 4, resolved):
/// true if [occurrencePath] identifies the currently-focused Occurrence's
/// own placed instance, or something nested inside it - a plain list-
/// prefix check against [focusedOccurrencePath]
/// (`AssemblyFocusStack.currentOccurrencePath`). This is the "and its
/// children" half of §2d's original deferred-to-Phase-4 language ("focus
/// part *and its children* opaque, peers and parents translucent") -
/// Phase 4 as first shipped only matched on `instance.partId ==
/// AssemblyFocusStack.current` (an exact target-Part match), which reads a
/// genuinely nested instance the same as a peer/parent; this function
/// replaces that exact-match check everywhere `PartViewport` decides
/// opacity/selectability (`_syncAssemblyInstanceNodes`/
/// `_hoverHitTestComponents`).
///
/// [focusedOccurrencePath] empty (nothing focused - `AssemblyFocusStack.
/// isFocused == false`) never matches anything; callers already gate on
/// that condition separately wherever they need the "nothing focused, so
/// treat everything as primary" fallback (mirrors
/// `mesh_geometry.dart`'s `assemblyInstanceOpacity`'s own `focusActive`
/// parameter being checked ahead of `isFocusedInstance`, not folded into
/// this function). [occurrencePath] shorter than [focusedOccurrencePath]
/// can never be a match (nothing is "nested inside" something deeper than
/// itself) - checked before the segment-by-segment comparison as a cheap
/// early exit, not because the loop below would get it wrong.
bool isOccurrencePathWithinFocus(List<String> occurrencePath, List<String> focusedOccurrencePath) {
  if (focusedOccurrencePath.isEmpty) return false;
  if (occurrencePath.length < focusedOccurrencePath.length) return false;
  for (var i = 0; i < focusedOccurrencePath.length; i++) {
    if (occurrencePath[i] != focusedOccurrencePath[i]) return false;
  }
  return true;
}

/// Assembly support Phase 5: the Move/Rotate gizmo's own live-drag overlay
/// - the pure matching logic behind `PartScreen._displayAssemblyInstances`,
/// kept separate and directly testable the same way
/// [applyOccurrenceVisibilityOverrides]/[applyInstanceVisibilityOverrides]
/// already are. Replaces the world transform of whichever instance's own
/// `occurrencePath` exactly equals [targetOccurrencePath] with
/// [transform] - every other instance passes through unchanged. Without
/// this, dragging the gizmo would move the manipulator handles while the
/// actual placed geometry stayed frozen at its pre-drag position until the
/// backend PATCH/refetch completed.
///
/// An exact-path match, not a prefix/containment one (unlike
/// [isOccurrencePathWithinFocus]) - the gizmo only ever moves the one
/// instance it's actually attached to, never anything nested inside it (a
/// child Occurrence's own placement is relative to its parent, so it moves
/// along automatically once the world transform this function *does*
/// override is recomposed - overriding it a second time here would be
/// wrong, not merely redundant).
List<AssemblyOccurrenceInstanceDto> overrideInstanceTransform(
  List<AssemblyOccurrenceInstanceDto> instances, {
  required List<String> targetOccurrencePath,
  required RigidTransformDto transform,
}) {
  return [
    for (final instance in instances)
      if (_pathEquals(instance.occurrencePath, targetOccurrencePath))
        AssemblyOccurrenceInstanceDto(
          occurrencePath: instance.occurrencePath,
          partId: instance.partId,
          worldTransform: transform,
          hidden: instance.hidden,
        )
      else
        instance,
  ];
}

bool _pathEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}
