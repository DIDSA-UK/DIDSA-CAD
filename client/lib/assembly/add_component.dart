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

import 'dart:convert';

import 'remint_identity.dart';

/// Raised for anything that stops [mergeComponentIntoDocument] from
/// producing a usable merged payload - never a partial/corrupt result.
class AddComponentException implements Exception {
  AddComponentException(this.message);

  final String message;

  @override
  String toString() => 'AddComponentException: $message';
}

/// What [_prepareComponent] decided about an incoming component payload.
class _PreparedComponent {
  _PreparedComponent({
    required this.parts,
    required this.sketches,
    required this.rootPartId,
    required this.reusesExistingPart,
  });

  /// The component's Parts (re-minted if a collision was healed).
  final List<Map<String, dynamic>> parts;
  final List<Map<String, dynamic>> sketches;

  /// The Part id the new/relinked Occurrence should resolve to.
  final String rootPartId;

  /// True when the file is already in the session under an earlier-minted
  /// copy: nothing from [parts]/[sketches] should be merged, just pointed at.
  final bool reusesExistingPart;
}

/// A canonical (key-sorted) JSON string, so two structurally equal maps
/// compare equal regardless of key order.
String _canonicalJson(Object? node) {
  Object? canonical(Object? value) {
    if (value is Map) {
      final keys = value.keys.map((k) => k as String).toList()..sort();
      return {for (final key in keys) key: canonical(value[key])};
    }
    if (value is List) return [for (final item in value) canonical(item)];
    return value;
  }

  return jsonEncode(canonical(node));
}

/// A Part's content minus the one field that legitimately differs between
/// "the file" and "the live session's copy of it": an Occurrence's
/// `resolved_part_id` (the composer pairs it with whichever Part it resolved
/// to in *that* payload, so a file read straight off disk carries none).
String _comparablePart(Map<String, dynamic> part) {
  final occurrences = ((part['occurrences'] as List?) ?? const []).cast<Map<String, dynamic>>();
  return _canonicalJson({
    ...part,
    'occurrences': [
      for (final occurrence in occurrences)
        {
          for (final entry in occurrence.entries)
            if (entry.key != 'resolved_part_id') entry.key: entry.value,
        },
    ],
  });
}

/// True when [componentParts]/[componentSketches] carry a Part or sketch id
/// the session already holds with *different* content - two different files
/// sharing an id (typically a pre-fix "Save As" copy), where dedup-by-id
/// would silently drop one of them. An id that matches with identical content
/// is just the same Part again, which is the ordinary, correct dedup.
bool _hasIdentityCollision({
  required List<Map<String, dynamic>> currentParts,
  required List<Map<String, dynamic>> componentParts,
  required List<Map<String, dynamic>> currentSketches,
  required List<Map<String, dynamic>> componentSketches,
}) {
  final currentPartById = {for (final part in currentParts) part['id'] as String: part};
  for (final part in componentParts) {
    final existing = currentPartById[part['id']];
    if (existing != null && _comparablePart(existing) != _comparablePart(part)) return true;
  }
  final currentSketchById = {for (final sketch in currentSketches) sketch['id'] as String: sketch};
  for (final sketch in componentSketches) {
    final existing = currentSketchById[sketch['id']];
    if (existing != null && _canonicalJson(existing) != _canonicalJson(sketch)) return true;
  }
  return false;
}

/// Part ids that existing Occurrences with this exact `external_ref` already
/// resolve to - "this file is already in the session", which is also how a
/// previously re-minted copy of a colliding file is found again.
List<String> _resolvedPartIdsForRef(List<Map<String, dynamic>> currentParts, String? externalRef) {
  if (externalRef == null) return const [];
  final found = <String>[];
  for (final part in currentParts) {
    for (final occurrence in ((part['occurrences'] as List?) ?? const []).cast<Map<String, dynamic>>()) {
      final resolved = occurrence['resolved_part_id'] as String?;
      if (occurrence['external_ref'] == externalRef && resolved != null && !found.contains(resolved)) {
        found.add(resolved);
      }
    }
  }
  return found;
}

/// Identity collision handling shared by [mergeComponentIntoDocument] and
/// [relocateOccurrenceInDocument] (bug report 2026-10-14, item 3). The merge
/// dedups by Part id and sketch id, which is only right when the same id
/// really means the same file. Two different files can share ids (a pre-fix
/// "Save As" copy, then edited), and dedup would silently drop the second one
/// - the Part the user asked for never shows up and its Occurrence points at
/// the other file's geometry. So:
///  * an id the session already holds with *identical* content is the same
///    Part again - the ordinary dedup, unchanged;
///  * the same [externalRef] already resolved in the session (or recorded in
///    [relativePathByPartId] for that Part) means "this file is already
///    here", possibly as a copy re-minted on an earlier add - the existing
///    Part is reused and nothing is merged;
///  * otherwise the incoming payload is re-minted before merging, so both
///    files end up as distinct Parts.
///
/// The self-reference check runs *after* that, on purpose: a Save-As copy of
/// the open Part carries the open Part's id but different content, and is a
/// legitimate thing to insert once re-minted. What still equals [rootPartId]
/// here is genuinely the open Part itself.
_PreparedComponent _prepareComponent({
  required Map<String, dynamic> componentPayload,
  required List<Map<String, dynamic>> componentParts,
  required String componentRootPartId,
  required List<Map<String, dynamic>> currentParts,
  required List<Map<String, dynamic>> currentSketches,
  required String rootPartId,
  required String? externalRef,
  required Map<String, String>? relativePathByPartId,
  required String selfReferenceMessage,
}) {
  var parts = componentParts;
  var sketches = ((componentPayload['sketches'] as List?) ?? const []).cast<Map<String, dynamic>>();
  var rootId = componentRootPartId;
  String? reuse;

  final sameRefPartIds = _resolvedPartIdsForRef(currentParts, externalRef);
  final knownPath = relativePathByPartId?[componentRootPartId];
  final sameSource = sameRefPartIds.contains(componentRootPartId) || (externalRef != null && knownPath == externalRef);
  if (!sameSource &&
      _hasIdentityCollision(
        currentParts: currentParts,
        componentParts: parts,
        currentSketches: currentSketches,
        componentSketches: sketches,
      )) {
    if (sameRefPartIds.isNotEmpty) {
      reuse = sameRefPartIds.first;
    } else {
      final reminted = remintNativeIdentity(componentPayload);
      final remintedDocument = reminted['document'] as Map<String, dynamic>;
      parts = (remintedDocument['parts'] as List).cast<Map<String, dynamic>>();
      sketches = ((reminted['sketches'] as List?) ?? const []).cast<Map<String, dynamic>>();
      rootId = remintedDocument['root_part_id'] as String? ?? parts.first['id'] as String;
    }
  }

  if (reuse == null && rootId == rootPartId) {
    throw AddComponentException(selfReferenceMessage);
  }
  return _PreparedComponent(
    parts: parts,
    sketches: sketches,
    rootPartId: reuse ?? rootId,
    reusesExistingPart: reuse != null,
  );
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
/// That dedup only applies when the id really means the same file. A
/// colliding id with *different* content (a pre-fix Save-As copy, edited) is
/// re-minted instead of silently dropped - see [_prepareComponent].
/// [relativePathByPartId] (the session's Part id -> project-relative path)
/// lets a Part already known to come from [externalRef] count as the same
/// file.
///
/// Throws [AddComponentException] for a `schema_version` mismatch, a file
/// with no Parts at all, a self-reference (the picked file is the open Part
/// itself: same root Part id *and* same content - inserting a Part into itself), or
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
  Map<String, String>? relativePathByPartId,
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
  final currentSketches = ((currentPayload['sketches'] as List?) ?? const [])
      .cast<Map<String, dynamic>>();

  final prepared = _prepareComponent(
    componentPayload: componentPayload,
    componentParts: componentParts,
    componentRootPartId: componentRootPartId,
    currentParts: currentParts,
    currentSketches: currentSketches,
    rootPartId: rootPartId,
    externalRef: externalRef,
    relativePathByPartId: relativePathByPartId,
    selfReferenceMessage: 'Cannot insert a Part into itself',
  );

  final mergedParts = [
    ...currentParts,
    if (!prepared.reusesExistingPart)
      for (final part in prepared.parts)
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
  final currentSketchIds = {for (final sketch in currentSketches) sketch['id'] as String};
  final mergedSketches = [
    ...currentSketches,
    if (!prepared.reusesExistingPart)
      for (final sketch in prepared.sketches)
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
    'resolved_part_id': prepared.rootPartId,
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
  Map<String, String>? relativePathByPartId,
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

  final currentSketches = ((currentPayload['sketches'] as List?) ?? const []).cast<Map<String, dynamic>>();
  final prepared = _prepareComponent(
    componentPayload: componentPayload,
    componentParts: componentParts,
    componentRootPartId: componentRootPartId,
    currentParts: currentParts,
    currentSketches: currentSketches,
    rootPartId: rootPartId,
    externalRef: newExternalRef,
    relativePathByPartId: relativePathByPartId,
    selfReferenceMessage: 'Cannot link a Part to itself',
  );

  final mergedParts = [
    ...currentParts,
    if (!prepared.reusesExistingPart)
      for (final part in prepared.parts)
        if (!currentPartIds.contains(part['id'])) part,
  ];

  final currentSketchIds = {for (final sketch in currentSketches) sketch['id'] as String};
  final mergedSketches = [
    ...currentSketches,
    if (!prepared.reusesExistingPart)
      for (final sketch in prepared.sketches)
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
                  'resolved_part_id': prepared.rootPartId,
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
