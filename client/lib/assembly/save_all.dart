/// Assembly support Phase 15 (`docs/assembly-scope.md` §6): the pure
/// correctness step behind `AssemblyDocumentClient.saveAll` - not named in
/// the roadmap's own one-paragraph brief, but required. `savePart`
/// (`assembly_document_client.dart`) just re-exports whatever
/// `Occurrence.external_ref` is currently stored server-side, which for a
/// Part merged in via "Add Component"/"Create Component…" is still a bare
/// picked-file display name or `null` (`add_component.dart`'s own doc
/// comment on why it can't know a real project-relative path at merge
/// time). Writing every Part's file with that stale/missing `external_ref`
/// would produce files whose cross-references silently fail to resolve on
/// a later `AssemblyGraphComposer.compose` - i.e. Save All would look like
/// it worked but produce an assembly that can't actually be reopened.
library;

/// Rewrites every Occurrence's own `external_ref` across every Part in
/// [documentPayload] (a full-session `DocumentApiClient.exportNative()`
/// snapshot, no `partId`) to the now-fully-known root-relative path of
/// whichever Part its `resolved_part_id` names, per [relativePathByPartId].
/// An Occurrence whose `resolved_part_id` has no entry in
/// [relativePathByPartId] yet (a Part Save All hasn't been given a path
/// for) is left exactly as it was - never cleared, never guessed.
Map<String, dynamic> stampExternalRefs({
  required Map<String, dynamic> documentPayload,
  required Map<String, String> relativePathByPartId,
}) {
  final document = documentPayload['document'];
  if (document is! Map) return documentPayload;
  final parts = (document['parts'] as List?) ?? const [];

  final stampedParts = [
    for (final partRaw in parts)
      if (partRaw is Map<String, dynamic>)
        {
          ...partRaw,
          'occurrences': [
            for (final occurrenceRaw in (partRaw['occurrences'] as List?) ?? const [])
              if (occurrenceRaw is Map<String, dynamic>)
                _stampOccurrence(occurrenceRaw, relativePathByPartId)
              else
                occurrenceRaw,
          ],
        }
      else
        partRaw,
  ];

  return {
    ...documentPayload,
    'document': {
      ...document,
      'parts': stampedParts,
    },
  };
}

Map<String, dynamic> _stampOccurrence(
  Map<String, dynamic> occurrence,
  Map<String, String> relativePathByPartId,
) {
  final resolvedPartId = occurrence['resolved_part_id'] as String?;
  final relativePath = resolvedPartId == null ? null : relativePathByPartId[resolvedPartId];
  if (relativePath == null) return occurrence;
  return {
    ...occurrence,
    'external_ref': relativePath,
  };
}

/// One Part's own `AssemblyDocumentClient.savePart` write failing during a
/// `saveAll` run (a revoked SAF grant, disk full) - collected rather than
/// aborting every other Part's own write.
class PartSaveFailure {
  PartSaveFailure({required this.partId, required this.relativePath, required this.message});

  final String partId;
  final String relativePath;
  final String message;
}

/// `AssemblyDocumentClient.saveAll`'s own result - every relative path that
/// was actually written, plus every one that failed (see [PartSaveFailure]).
class SaveAllResult {
  SaveAllResult({required this.savedRelativePaths, required this.failures});

  final List<String> savedRelativePaths;
  final List<PartSaveFailure> failures;

  bool get hasFailures => failures.isNotEmpty;
}
