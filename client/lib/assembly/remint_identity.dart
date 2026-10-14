/// Dart twin of `backend/app/document/remint_identity.py` - keep the two in
/// matching shape.
///
/// Why this exists (bug report 2026-10-14, item 3): a native file's
/// `document.id`, Part ids and sketch ids are minted once, when the Part is
/// first created, and then trusted verbatim on every later import. Both the
/// backend Document (parts keyed by id) and its sketch store are
/// *session-global*, so two different files that carry the same ids (the
/// usual cause: "Save As" copied a Part byte-for-byte and the copy was then
/// edited) overwrite one another as soon as they share a session - every
/// merge path dedups by id on the assumption that the same id means the same
/// file.
///
/// [remintNativeIdentity] fixes both halves: Save As runs it so copies never
/// share ids in the first place, and the merge/compose paths run it on an
/// incoming payload whose ids already exist in the session with different
/// content (files already on disk, written before Save As re-minted).
library;

import 'package:uuid/uuid.dart';

/// Every session-global id in [payload]: `document.id`, each Part id and each
/// sketch id. Feature, entity and point ids are deliberately absent - they
/// are scoped to their Part or sketch (routes are
/// `/parts/{part_id}/features/{feature_id}`, the body cache is keyed by Part
/// id), so a copy keeping them cannot collide with anything.
Set<String> collectNativeIdentityIds(Map<String, dynamic> payload) {
  final ids = <String>{};
  final document = payload['document'];
  if (document is Map) {
    final documentId = document['id'];
    if (documentId is String) ids.add(documentId);
    final parts = document['parts'];
    if (parts is List) {
      for (final part in parts) {
        final partId = part is Map ? part['id'] : null;
        if (partId is String) ids.add(partId);
      }
    }
  }
  final sketches = payload['sketches'];
  if (sketches is List) {
    for (final sketch in sketches) {
      final sketchId = sketch is Map ? sketch['id'] : null;
      if (sketchId is String) ids.add(sketchId);
    }
  }
  return ids;
}

/// Returns a deep copy of [payload] where `document.id`, every Part id and
/// every sketch id (restricted to [onlyIds] when given) is replaced by a
/// fresh UUID v4, and every *reference* to one of them follows.
///
/// References are found by walking the whole JSON tree and replacing every
/// string **value** exactly equal to an old id, rather than by listing the
/// reference sites (`SketchFeature.sketch_id`, `profile_refs[].sketch_id`,
/// `root_part_id`, an Occurrence's `resolved_part_id`, anything added later):
/// UUIDs are unique strings, so an exact match is never a false positive.
/// Map **keys** are left alone - the only id-keyed maps in the format are
/// keyed by Part-scoped feature ids, which this does not touch.
///
/// [idGenerator] exists for tests; production callers leave it null.
Map<String, dynamic> remintNativeIdentity(
  Map<String, dynamic> payload, {
  Set<String>? onlyIds,
  String Function()? idGenerator,
}) {
  var candidates = collectNativeIdentityIds(payload);
  if (onlyIds != null) candidates = candidates.intersection(onlyIds);
  final generate = idGenerator ?? () => const Uuid().v4();
  final mapping = {for (final old in candidates) old: generate()};
  return _replace(payload, mapping) as Map<String, dynamic>;
}

Object? _replace(Object? node, Map<String, String> mapping) {
  if (node is String) return mapping[node] ?? node;
  if (node is List) return [for (final item in node) _replace(item, mapping)];
  if (node is Map) {
    return <String, dynamic>{
      for (final entry in node.entries) entry.key as String: _replace(entry.value, mapping),
    };
  }
  return node;
}
