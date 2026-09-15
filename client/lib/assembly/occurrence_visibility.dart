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
