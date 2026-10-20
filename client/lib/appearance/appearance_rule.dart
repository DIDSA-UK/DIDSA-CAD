/// The Appearance tool's record and resolution rule (`docs/appearance-tool-scope.md` sections 2, D2, D3): a line-for-line
/// copy of the backend's reference, `backend/app/document/appearance.py`, checked against its golden vectors
/// (`docs/appearance/vectors.json`, `test/appearance_rule_test.dart`). DIDSA-VR keeps a GDScript copy of the same rule.
///
/// It works on the reference's plain resolution model (JSON-shaped maps):
///
///     {"parts": {partId: {
///         "appearance": {...}, "body_appearances": {bodyId: {...}},
///         "face_appearances": [{"face": {"body_id", "index"}, "appearance": {...}}],
///         "appearance_overrides": [{"path", "scope"?, "pattern_id"?, "part_id"?, "body_id"?, "face"?, "appearance"}],
///         "occurrences": {occurrenceId: {"part_id": ..., "color": "#RRGGBB" | null}},
///     }}}
///
/// Which appearance wins, field by field: the scene shown, then the overrides of the assembly viewed, then those of each
/// sub-assembly file on the way down (ending with the leaf's own list), then the leaf's own face / body / whole record.
/// Within one list the most specific target wins (face > body > node; then the nearest node; then a named path > every
/// copy of a pattern > every placement of a Part > the whole assembly); a tie goes to the later entry.
library;

typedef Json = Map<String, dynamic>;

const List<String> kAppearanceFields = ['colour', 'opacity', 'metallic', 'roughness', 'emission', 'emission_strength'];
const String kScopePattern = 'pattern';
const String kScopeSamePart = 'same_part';
const String kPatternSegment = '#pattern:';
const double kEmissionStrengthMax = 10.0;
final RegExp _hexRe = RegExp(r'^#[0-9A-Fa-f]{6}$');

bool isHexColour(Object? value) => value is String && _hexRe.hasMatch(value);

/// Why [data] is not a valid appearance record (empty when it is): the backend's `appearance_errors`.
List<String> appearanceErrors(Object? data) {
  if (data is! Map) return ['appearance must be an object'];
  final errors = <String>[
    for (final key in data.keys)
      if (!kAppearanceFields.contains(key)) "unknown appearance field '$key'",
  ];
  if (!kAppearanceFields.any((k) => data[k] != null)) errors.add('an appearance must set at least one field');
  for (final key in const ['colour', 'emission']) {
    final value = data[key];
    if (value != null && !isHexColour(value)) errors.add("$key must be '#RRGGBB'");
  }
  for (final key in const ['opacity', 'metallic', 'roughness', 'emission_strength']) {
    final value = data[key];
    if (value == null) continue;
    final upper = key == 'emission_strength' ? kEmissionStrengthMax : 1.0;
    if (value is! num || value < 0 || value > upper) {
      errors.add('$key must be a number from 0 to ${upper == upper.roundToDouble() ? upper.toInt() : upper}');
    }
  }
  return errors;
}

/// The occurrence id of a path segment: a pattern copy `<source>#pattern:<pattern id>:<index>` names `<source>`.
String baseSegment(String segment) {
  final at = segment.indexOf(kPatternSegment);
  return at < 0 ? segment : segment.substring(0, at);
}

List<String> splitPath(String path) => path.isEmpty ? <String>[] : path.split('/');

/// What one override targets; an assembly holds at most one override per key (PUT replaces it).
String overrideKey(Json record) {
  final face = record['face'];
  return [
    record['path'] ?? '',
    record['scope'],
    record['pattern_id'],
    record['part_id'],
    record['body_id'],
    face is Map ? face['index'] : null,
  ].join('\u0000');
}

bool _listEquals(List<String> a, List<String> b) {
  if (a.length != b.length) return false;
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return false;
  }
  return true;
}

/// A Part's own override list with the legacy `Occurrence.color` aliases folded in.
List<Json> effectiveOverrides(Json part) {
  final explicit = [for (final r in (part['appearance_overrides'] as List?) ?? const []) Map<String, dynamic>.from(r as Map)];
  final byKey = <String, int>{for (var i = 0; i < explicit.length; i++) overrideKey(explicit[i]): i};
  final legacy = <Json>[];
  final occurrences = (part['occurrences'] as Map?) ?? const {};
  for (final entry in occurrences.entries) {
    final colour = (entry.value as Map)['color'];
    if (colour == null || colour == '') continue;
    final key = overrideKey({'path': entry.key});
    final at = byKey[key];
    if (at != null) {
      final record = explicit[at];
      final appearance = Map<String, dynamic>.from(record['appearance'] as Map);
      if (appearance['colour'] == null) {
        appearance['colour'] = colour;
        explicit[at] = {...record, 'appearance': appearance};
      }
    } else {
      legacy.add({
        'path': entry.key,
        'appearance': {'colour': colour},
      });
    }
  }
  return [...legacy, ...explicit];
}

/// `(subshape, depth, kind)` when [record] applies to the face ([bodyId], [faceIndex]) of the instance [suffix] below the
/// record's own Part (`suffixParts[j]` is the Part placed by `suffix[j]`), else null. Larger wins.
List<int>? _specificity(Json record, List<String> suffix, List<String?> suffixParts, String? bodyId, int? faceIndex) {
  final face = record['face'] as Map?;
  final recordBody = (record['body_id'] as String?) ?? (face?['body_id'] as String?);
  final subshape = face != null ? 2 : (recordBody != null ? 1 : 0);
  if (subshape > 0) {
    if (recordBody != bodyId) return null;
    if (face != null && (face['index'] as num?)?.toInt() != faceIndex) return null;
  }
  final scope = record['scope'];
  if (scope == kScopeSamePart) {
    var anchor = -1;
    for (var j = 0; j < suffixParts.length; j++) {
      if (suffixParts[j] == record['part_id']) anchor = j;
    }
    if (anchor < 0) return null;
    final depth = anchor + 1;
    if (subshape > 0 && depth != suffix.length) return null;
    return [subshape, depth, 1];
  }
  final segments = splitPath((record['path'] as String?) ?? '');
  final n = segments.length;
  if (scope == kScopePattern) {
    if (n == 0 || suffix.length < n || !_listEquals(suffix.sublist(0, n - 1), segments.sublist(0, n - 1))) return null;
    final source = segments[n - 1];
    final segment = suffix[n - 1];
    if (segment != source && !segment.startsWith('$source$kPatternSegment${record['pattern_id']}:')) return null;
    if (subshape > 0 && suffix.length != n) return null;
    return [subshape, n, 2];
  }
  if (suffix.length < n || !_listEquals(suffix.sublist(0, n), segments)) return null;
  if (n == 0 && subshape == 0) return [0, 0, 0];
  if (subshape > 0 && suffix.length != n) return null;
  return [subshape, n, 3];
}

int _compareSpec(List<int> a, List<int> b) {
  for (var i = 0; i < a.length; i++) {
    if (a[i] != b[i]) return a[i].compareTo(b[i]);
  }
  return 0;
}

List<Json> _orderedMatches(List<Json> records, List<String> suffix, List<String?> suffixParts, String? bodyId, int? faceIndex) {
  final matched = <(List<int>, int, Json)>[];
  for (var i = 0; i < records.length; i++) {
    final spec = _specificity(records[i], suffix, suffixParts, bodyId, faceIndex);
    if (spec != null) matched.add((spec, i, Map<String, dynamic>.from(records[i]['appearance'] as Map)));
  }
  matched.sort((a, b) {
    final bySpec = _compareSpec(b.$1, a.$1);
    return bySpec != 0 ? bySpec : b.$2.compareTo(a.$2);
  });
  return [for (final m in matched) m.$3];
}

Json _part(Json model, String id) => Map<String, dynamic>.from((model['parts'] as Map)[id] as Map);

/// The Part ids from the root down to the instance [path] names (`path.length + 1` of them), or null when a segment does
/// not resolve.
List<String>? instanceChain(Json model, String rootId, List<String> path) {
  final parts = (model['parts'] as Map?) ?? const {};
  final chain = <String>[rootId];
  for (final segment in path) {
    final part = parts[chain.last] as Map?;
    final occurrence = ((part?['occurrences'] as Map?) ?? const {})[baseSegment(segment)] as Map?;
    final partId = occurrence?['part_id'];
    if (occurrence == null || partId is! String || !parts.containsKey(partId)) return null;
    chain.add(partId);
  }
  if (!parts.containsKey(rootId)) return null;
  return chain;
}

/// Every appearance record that applies to one face (or, with [bodyId] null, to the instance as a whole), highest first.
List<Json> resolveLayers(Json model, String rootId, List<String> path,
    {String? bodyId, int? faceIndex, List<Json>? sceneOverrides}) {
  final chain = instanceChain(model, rootId, path);
  if (chain == null) return const [];
  final layers = <Json>[];
  if (sceneOverrides != null && sceneOverrides.isNotEmpty) {
    layers.addAll(_orderedMatches(sceneOverrides, path, chain.sublist(1), bodyId, faceIndex));
  }
  for (var k = 0; k < chain.length; k++) {
    layers.addAll(_orderedMatches(effectiveOverrides(_part(model, chain[k])), path.sublist(k), chain.sublist(k + 1), bodyId, faceIndex));
  }
  final leaf = _part(model, chain.last);
  if (bodyId != null) {
    for (final entry in (leaf['face_appearances'] as List?) ?? const []) {
      final face = (entry as Map)['face'] as Map;
      if (face['body_id'] == bodyId && (face['index'] as num?)?.toInt() == faceIndex) {
        layers.add(Map<String, dynamic>.from(entry['appearance'] as Map));
      }
    }
    final body = ((leaf['body_appearances'] as Map?) ?? const {})[bodyId];
    if (body is Map && body.isNotEmpty) layers.add(Map<String, dynamic>.from(body));
  }
  final own = leaf['appearance'];
  if (own is Map && own.isNotEmpty) layers.add(Map<String, dynamic>.from(own));
  return layers;
}

/// Field by field, the first layer that sets a field wins. Only fields something sets are in the result.
Json mergeLayers(List<Json> layers) {
  final out = <String, dynamic>{};
  for (final layer in layers) {
    for (final name in kAppearanceFields) {
      if (!out.containsKey(name) && layer[name] != null) out[name] = layer[name];
    }
  }
  return out;
}

/// The resolved appearance of one face ([bodyId], [faceIndex]) of the instance at [path] (`[]` = the root's own bodies)
/// in [rootId]'s assembly with [sceneOverrides] shown. Only the fields something sets.
Json resolveAppearance(Json model, String rootId, List<String> path,
        {String? bodyId, int? faceIndex, List<Json>? sceneOverrides}) =>
    mergeLayers(resolveLayers(model, rootId, path, bodyId: bodyId, faceIndex: faceIndex, sceneOverrides: sceneOverrides));

/// [resolveAppearance] for many faces of one instance at once (the node-level matches found once). Keys are
/// `'$bodyId|$faceIndex'`.
Map<String, Json> resolveFaces(Json model, String rootId, List<String> path, List<(String, int)> faces,
    {List<Json>? sceneOverrides}) {
  final chain = instanceChain(model, rootId, path);
  if (chain == null) return {for (final f in faces) '${f.$1}|${f.$2}': <String, dynamic>{}};
  final lists = <(List<Json>, List<String>, List<String?>)>[];
  if (sceneOverrides != null && sceneOverrides.isNotEmpty) lists.add((sceneOverrides, path, chain.sublist(1)));
  for (var k = 0; k < chain.length; k++) {
    lists.add((effectiveOverrides(_part(model, chain[k])), path.sublist(k), chain.sublist(k + 1)));
  }
  final nodeMatches = [for (final l in lists) _orderedMatches(l.$1, l.$2, l.$3, null, null)];
  final subshapeRecords = [
    for (final l in lists) [for (final r in l.$1) if (r['face'] != null || r['body_id'] != null) r],
  ];
  final leaf = _part(model, chain.last);
  final leafFaces = (leaf['face_appearances'] as List?) ?? const [];
  final leafBodies = (leaf['body_appearances'] as Map?) ?? const {};
  final own = leaf['appearance'];
  final out = <String, Json>{};
  for (final (bodyId, faceIndex) in faces) {
    final layers = <Json>[];
    for (var p = 0; p < lists.length; p++) {
      if (subshapeRecords[p].isNotEmpty) {
        layers.addAll(_orderedMatches(subshapeRecords[p], lists[p].$2, lists[p].$3, bodyId, faceIndex));
      }
      layers.addAll(nodeMatches[p]);
    }
    for (final entry in leafFaces) {
      final face = (entry as Map)['face'] as Map;
      if (face['body_id'] == bodyId && (face['index'] as num?)?.toInt() == faceIndex) {
        layers.add(Map<String, dynamic>.from(entry['appearance'] as Map));
      }
    }
    final body = leafBodies[bodyId];
    if (body is Map && body.isNotEmpty) layers.add(Map<String, dynamic>.from(body));
    if (own is Map && own.isNotEmpty) layers.add(Map<String, dynamic>.from(own));
    out['$bodyId|$faceIndex'] = mergeLayers(layers);
  }
  return out;
}
