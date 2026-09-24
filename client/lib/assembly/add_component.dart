/// Assembly support Phase 3b (`docs/assembly-scope.md` §3): the pure merge
/// step behind "Add Component > Insert Existing Component". Closes the gap
/// Phase 3 left open (Assembly lens was read/view-only - no in-UI way to add
/// a first component) without needing a new backend mutation endpoint: the
/// only existing way to establish an Occurrence is a full `import_native`
/// replace (Phase 0/2), so this folds a separately-picked `.didsa` file's
/// own exported document into the *current* session's own full document
/// snapshot (`DocumentApiClient.exportNative()`, no `partId` - every Part
/// already live in this backend session, in-memory, reflecting every edit
/// made so far even if never saved to a file) and hands the result straight
/// back to `DocumentApiClient.importNative` (a full replace, exactly the
/// same semantics `PartScreen._openNativeFile` already relies on elsewhere
/// in this app).
///
/// Deliberately does **not** go through `StorageService`/`ProjectRoot`/
/// `AssemblyGraphComposer` (Phase 1/2's own multi-file-open machinery) -
/// `PartScreen` has no project-root session of its own to resolve a
/// relative path against (a real gap, not a deliberate design choice - see
/// this phase's own entry in `docs/assembly-scope.md`), so this reuses the
/// same `file_picker`-based single-file flow `_openNativeFile`/
/// `_importGeometry` already use instead. `externalRef` is therefore only
/// the picked file's own display name (e.g. `"bracket.didsa"`), not a real
/// project-relative path - still a legitimate, opaque, client-owned
/// identity per `docs/assembly-scope.md` decision #6, just not one that can
/// be re-resolved automatically on a later reload the way a true
/// `StorageService`-backed one could.
library;

/// Raised for anything that stops [mergeComponentIntoDocument] from
/// producing a usable merged payload - never a partial/corrupt result.
class AddComponentException implements Exception {
  AddComponentException(this.message);

  final String message;

  @override
  String toString() => 'AddComponentException: $message';
}

/// Merges [componentPayload] (a picked file's own `export_native` JSON,
/// `partId: null` or otherwise - either shape has a `document.parts` list)
/// into [currentPayload] (this session's own full snapshot,
/// `DocumentApiClient.exportNative()` with no `partId`), adding one new
/// Occurrence naming [occurrenceId] onto whichever Part in [currentPayload]
/// has id [rootPartId].
///
/// Dedups by the incoming Part's own persisted `id` (never reassigned on
/// import - `native_format.py`'s `_part_from_dict` trusts the wire's own
/// `"id"` verbatim, the same rule `AssemblyGraphComposer` already relies
/// on): inserting the same file a second time adds a second Occurrence of
/// the *same* underlying Part rather than a duplicate Part entry, mirroring
/// Phase 2's "two Occurrences resolving to one Part is an ordinary dedup"
/// behaviour even without a `ProjectRoot`-relative-path identity to key off
/// here.
///
/// Throws [AddComponentException] for a `schema_version` mismatch, a file
/// with no Parts at all, a self-reference (the picked file's own root Part
/// id already equals [rootPartId] - inserting a Part into itself), or
/// [rootPartId] not actually being present in [currentPayload] (should
/// never happen in practice - the currently-open Part always exports
/// itself - but fails loudly rather than silently dropping the new
/// Occurrence if it somehow did).
Map<String, dynamic> mergeComponentIntoDocument({
  required Map<String, dynamic> currentPayload,
  required Map<String, dynamic> componentPayload,
  required String rootPartId,
  required String occurrenceId,
  String? externalRef,
  String? nameOverride,
}) {
  final currentSchema = currentPayload['schema_version'];
  final componentSchema = componentPayload['schema_version'];
  if (componentSchema == null || componentSchema != currentSchema) {
    throw AddComponentException('Unsupported or mismatched native file version');
  }

  final componentDocument = componentPayload['document'];
  if (componentDocument is! Map) {
    throw AddComponentException('Not a valid native project file');
  }
  final componentPartsRaw = componentDocument['parts'];
  if (componentPartsRaw is! List || componentPartsRaw.isEmpty) {
    throw AddComponentException('File contains no Parts');
  }
  final componentParts = componentPartsRaw.cast<Map<String, dynamic>>();
  final componentRootPartId =
      componentDocument['root_part_id'] as String? ?? componentParts.first['id'] as String;

  if (componentRootPartId == rootPartId) {
    throw AddComponentException('Cannot insert a Part into itself');
  }

  final currentDocument = currentPayload['document'];
  if (currentDocument is! Map) {
    throw AddComponentException('Current session has no document to add to');
  }
  final currentParts = ((currentDocument['parts'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  if (!currentParts.any((part) => part['id'] == rootPartId)) {
    throw AddComponentException('Current Part is missing from its own session snapshot');
  }
  final currentPartIds = {for (final part in currentParts) part['id'] as String};

  final mergedParts = [
    ...currentParts,
    for (final part in componentParts)
      if (!currentPartIds.contains(part['id'])) part,
  ];

  // Bug fix: `export_native`'s `sketches` list (`native_format.py`) lives
  // alongside `document`, not inside it - every Sketch referenced by any
  // SketchFeature across the exported Parts, keyed by id in the backend's
  // own global sketch store (`replace_all_sketches` on `POST
  // /import/native`, a full replace of that store). Dropping
  // [componentPayload]'s own `sketches` here left every SketchFeature on
  // the newly-merged Part (e.g. an Extrude) pointing at a sketch id the
  // re-imported store never received - `compute_part_bodies` then 404s via
  // `get_sketch_or_404`, so the new Occurrence shows up in the tree (parts
  // merged fine) but never renders (its geometry can't be computed).
  // Deduped by sketch id, same convention as [mergedParts] above.
  final currentSketches = ((currentPayload['sketches'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final componentSketches = ((componentPayload['sketches'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();
  final currentSketchIds = {for (final sketch in currentSketches) sketch['id'] as String};
  final mergedSketches = [
    ...currentSketches,
    for (final sketch in componentSketches)
      if (!currentSketchIds.contains(sketch['id'])) sketch,
  ];

  // Bug report (assembly testing): "The first part added to an assembly
  // should have a fix constraint auto applied" - a Mate-driven placement is
  // only ever meaningful relative to at least one fixed reference, the same
  // "first component is grounded by convention" rule real CAD tools apply.
  // Determined from `rootPartId`'s own pre-merge Occurrence list (the same
  // one `currentParts`, still un-mutated at this point, already holds) -
  // this is genuinely the first Occurrence exactly when that list is empty.
  final currentRootPart = currentParts.firstWhere((part) => part['id'] == rootPartId);
  final existingOccurrences = (currentRootPart['occurrences'] as List?) ?? const [];
  final isFirstOccurrence = existingOccurrences.isEmpty;

  final newOccurrence = <String, dynamic>{
    'id': occurrenceId,
    'external_ref': externalRef,
    'resolved_part_id': componentRootPartId,
    'name_override': nameOverride,
    'transform': null,
    'suppressed': false,
    'hidden': false,
    'fixed': isFirstOccurrence,
  };

  final updatedParts = [
    for (final part in mergedParts)
      if (part['id'] == rootPartId)
        {
          ...part,
          'occurrences': [
            ...((part['occurrences'] as List?) ?? const []),
            newOccurrence,
          ],
        }
      else
        part,
  ];

  return {
    ...currentPayload,
    'document': {
      ...currentDocument,
      'parts': updatedParts,
    },
    'sketches': mergedSketches,
  };
}

/// Bug fix (assembly testing: "if the software cannot find the file, it
/// should ask for its location") - [mergeComponentIntoDocument]'s own
/// sibling for re-linking an *already-existing* Occurrence whose reference
/// couldn't be resolved (`OccurrenceDto.resolvedPartId == null`), rather
/// than adding a brand-new one: merges [componentPayload]'s own Part(s) into
/// [currentPayload] exactly the same deduped way, then updates the
/// Occurrence named [occurrenceId] (on whichever Part has id [rootPartId])
/// in place - its own `external_ref`/`resolved_part_id` point at the
/// newly-picked file's root Part, every other field (`transform`, `hidden`,
/// `fixed`, `color`, ...) left completely untouched, so re-linking a
/// misplaced file doesn't also reset how it was positioned/configured.
///
/// Throws [AddComponentException] for the same reasons
/// [mergeComponentIntoDocument] does, plus [occurrenceId] not actually
/// naming an Occurrence on [rootPartId] (should never happen in practice -
/// this is only ever called from the exact row that's showing the
/// unresolved Occurrence - but fails loudly rather than silently no-op'ing
/// if it somehow did).
Map<String, dynamic> relocateOccurrenceInDocument({
  required Map<String, dynamic> currentPayload,
  required Map<String, dynamic> componentPayload,
  required String rootPartId,
  required String occurrenceId,
  String? newExternalRef,
}) {
  final currentSchema = currentPayload['schema_version'];
  final componentSchema = componentPayload['schema_version'];
  if (componentSchema == null || componentSchema != currentSchema) {
    throw AddComponentException('Unsupported or mismatched native file version');
  }

  final componentDocument = componentPayload['document'];
  if (componentDocument is! Map) {
    throw AddComponentException('Not a valid native project file');
  }
  final componentPartsRaw = componentDocument['parts'];
  if (componentPartsRaw is! List || componentPartsRaw.isEmpty) {
    throw AddComponentException('File contains no Parts');
  }
  final componentParts = componentPartsRaw.cast<Map<String, dynamic>>();
  final componentRootPartId =
      componentDocument['root_part_id'] as String? ?? componentParts.first['id'] as String;

  if (componentRootPartId == rootPartId) {
    throw AddComponentException('Cannot link a Part to itself');
  }

  final currentDocument = currentPayload['document'];
  if (currentDocument is! Map) {
    throw AddComponentException('Current session has no document to add to');
  }
  final currentParts = ((currentDocument['parts'] as List?) ?? const []).cast<Map<String, dynamic>>();
  final currentRootPart = currentParts.firstWhere(
    (part) => part['id'] == rootPartId,
    orElse: () => throw AddComponentException('Current Part is missing from its own session snapshot'),
  );
  final existingOccurrences = ((currentRootPart['occurrences'] as List?) ?? const []).cast<Map<String, dynamic>>();
  if (!existingOccurrences.any((occurrence) => occurrence['id'] == occurrenceId)) {
    throw AddComponentException('That component is no longer part of this assembly');
  }
  final currentPartIds = {for (final part in currentParts) part['id'] as String};

  final mergedParts = [
    ...currentParts,
    for (final part in componentParts)
      if (!currentPartIds.contains(part['id'])) part,
  ];

  final currentSketches = ((currentPayload['sketches'] as List?) ?? const []).cast<Map<String, dynamic>>();
  final componentSketches = ((componentPayload['sketches'] as List?) ?? const []).cast<Map<String, dynamic>>();
  final currentSketchIds = {for (final sketch in currentSketches) sketch['id'] as String};
  final mergedSketches = [
    ...currentSketches,
    for (final sketch in componentSketches)
      if (!currentSketchIds.contains(sketch['id'])) sketch,
  ];

  final updatedParts = [
    for (final part in mergedParts)
      if (part['id'] == rootPartId)
        {
          ...part,
          'occurrences': [
            for (final occurrence in existingOccurrences)
              if (occurrence['id'] == occurrenceId)
                {
                  ...occurrence,
                  'external_ref': newExternalRef ?? occurrence['external_ref'],
                  'resolved_part_id': componentRootPartId,
                }
              else
                occurrence,
          ],
        }
      else
        part,
  ];

  return {
    ...currentPayload,
    'document': {
      ...currentDocument,
      'parts': updatedParts,
    },
    'sketches': mergedSketches,
  };
}
