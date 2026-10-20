/// The flat app's side of the Appearance tool (`docs/appearance-tool-scope.md` V3): the resolution model the rule runs on
/// (`appearance_rule.dart`), read from the backend, and what a paint does with it. DIDSA-VR's `appearance_tool.gd` is the
/// same thing in GDScript.
///
/// The model is built from the backend's own lists: `GET /parts/{id}` (the Part's own appearance, its bodies' and faces'),
/// `GET /parts/{id}/appearance-overrides` (faces at their current index), the occurrence rows and the component patterns,
/// for every Part under the root. Painting is an override in the assembly being viewed (the [root]), never an edit of a placed
/// part's file: `PUT /parts/{root}/appearance-overrides` with the row's target and the merged appearance (`null` clears).
///
/// On top of the model sit, highest first: the [temporary] layer (a shown scene's looks, and what is painted while a scene
/// shows: nothing is sent) and a previewed row ([preview]).
library;

import 'package:flutter/foundation.dart';

import '../api/document_api_client.dart';
import '../api/sketch_api_client.dart' show ApiException;
import 'appearance_look.dart';
import 'appearance_rule.dart';

/// One row of the paint list (D1): what a paint on it targets ([record], no appearance), what it covers ([members], joined
/// instance paths), whether that level has its own paint ([setHere]) and what shows there now ([swatch]).
class PaintRow {
  final String id;
  final String label;
  final Json record;
  final List<String> members;
  final bool setHere;
  final Json swatch;

  const PaintRow({
    required this.id,
    required this.label,
    required this.record,
    required this.members,
    this.setHere = false,
    this.swatch = const {},
  });
}

/// The built-in saved appearances (section 2's presets).
const List<(String, Json)> kAppearancePresets = [
  ('Matte plastic', {'metallic': 0.0, 'roughness': 0.9}),
  ('Gloss plastic', {'metallic': 0.0, 'roughness': 0.15}),
  ('Brushed metal', {'metallic': 1.0, 'roughness': 0.45}),
  ('Polished metal', {'metallic': 1.0, 'roughness': 0.08}),
  ('Glass', {'opacity': 0.25, 'metallic': 0.0, 'roughness': 0.05}),
  ('Glowing', {'emission_strength': 2.0}),
];

class AppearanceModel extends ChangeNotifier {
  final DocumentApiClient api;

  AppearanceModel(this.api);

  /// The assembly being viewed: where a paint goes.
  String root = '';

  Json _model = {'parts': <String, dynamic>{}};
  final Map<String, List<ComponentPatternDto>> _patterns = {};
  final Map<String, String> _names = {};
  final Set<String> _loaded = {};

  /// The top layer: a shown scene's appearance overrides plus what is painted while it shows (never sent). Null = no scene.
  List<Json>? temporary;
  Json? _preview; // {record, appearance (empty = Clear)}

  Json get model => _model;
  bool get isTemporary => temporary != null;

  /// Forgets everything read (a reload, another document).
  void forget() {
    _model = {'parts': <String, dynamic>{}};
    _patterns.clear();
    _names.clear();
    _loaded.clear();
    _preview = null;
    notifyListeners();
  }

  String partName(String partId) => _names[partId] ?? partId;

  /// Reads every Part under [rootId] into the model (Parts already read are not read again).
  Future<void> ensureLoaded(String rootId) async {
    root = rootId;
    final queue = <String>[rootId];
    final seen = <String>{};
    while (queue.isNotEmpty) {
      final pid = queue.removeAt(0);
      if (!seen.add(pid)) continue;
      if (!_loaded.contains(pid)) await _load(pid);
      final occurrences = ((_parts[pid] as Map?)?['occurrences'] as Map?) ?? const {};
      for (final occ in occurrences.values) {
        final child = (occ as Map)['part_id'] as String?;
        if (child != null && !seen.contains(child)) queue.add(child);
      }
    }
    notifyListeners();
  }

  Map<String, dynamic> get _parts => _model['parts'] as Map<String, dynamic>;

  /// [read], or [fallback] when the backend refuses it (one Part that can't be read paints nothing of its own; the rest
  /// still resolve).
  static Future<T> _orElse<T>(Future<T> Function() read, T fallback) async {
    try {
      return await read();
    } on ApiException {
      return fallback;
    }
  }

  Future<void> _load(String pid) async {
    final entry = <String, dynamic>{'occurrences': <String, dynamic>{}};
    final part = await _orElse(() => api.getPartJson(pid), <String, dynamic>{});
    _names[pid] = (part['name'] as String?) ?? pid;
    if (part['appearance'] is Map && (part['appearance'] as Map).isNotEmpty) entry['appearance'] = part['appearance'];
    if (part['body_appearances'] is Map && (part['body_appearances'] as Map).isNotEmpty) {
      entry['body_appearances'] = part['body_appearances'];
    }
    final faces = [
      for (final f in (part['face_appearances'] as List?) ?? const [])
        if ((f as Map)['current_index'] != null)
          {
            'face': {'body_id': f['face']['body_id'], 'index': (f['current_index'] as num).toInt()},
            'appearance': f['appearance'],
          },
    ];
    if (faces.isNotEmpty) entry['face_appearances'] = faces;
    for (final o in await _orElse(() => api.listOccurrences(pid), const <OccurrenceDto>[])) {
      if (o.suppressed || o.resolvedPartId == null) continue;
      (entry['occurrences'] as Map)[o.id] = {'part_id': o.resolvedPartId, 'color': o.color, 'hidden': o.hidden};
    }
    _setOverrides(entry, await _orElse(() => api.getAppearanceOverrides(pid), const <Json>[]));
    _patterns[pid] = await _orElse(() => api.listComponentPatterns(pid), const <ComponentPatternDto>[]);
    _parts[pid] = entry;
    _loaded.add(pid);
  }

  /// The backend's override list into the model: legacy colours are already in the occurrences, unresolved ones paint
  /// nothing, and a face is matched at its current index.
  static void _setOverrides(Json entry, List<Json> listed) {
    final records = [
      for (final o in listed)
        if (o['legacy'] != true && o['unresolved'] == null) recordFromWire(o),
    ];
    if (records.isEmpty) {
      entry.remove('appearance_overrides');
    } else {
      entry['appearance_overrides'] = records;
    }
  }

  /// An override (or scene override) from the wire as a rule record.
  static Json recordFromWire(Json o) {
    final r = <String, dynamic>{'path': (o['path'] as String?) ?? '', 'appearance': o['appearance'] ?? const {}};
    for (final k in const ['scope', 'pattern_id', 'part_id', 'body_id']) {
      if (o[k] != null) r[k] = o[k];
    }
    final face = o['face'];
    if (face is Map) {
      final index = o['face_current_index'] ?? face['index'];
      r['face'] = {'body_id': face['body_id'], 'shape_type': 'face', 'index': (index as num).toInt()};
      r['body_id'] = face['body_id'];
    }
    return r;
  }

  // --- what shows -----------------------------------------------------------------------------------------------

  /// The model with a previewed row applied in the root's own list (a preview of a real paint).
  Json get _shownModel {
    final preview = _preview;
    if (preview == null || isTemporary) return _model;
    final parts = Map<String, dynamic>.from(_parts);
    final entry = Map<String, dynamic>.from((parts[root] as Map?) ?? const {});
    entry['appearance_overrides'] =
        withRecord((entry['appearance_overrides'] as List?)?.cast<Json>() ?? const [], preview['record'] as Json, preview['appearance'] as Json);
    parts[root] = entry;
    return {'parts': parts};
  }

  /// The layer on top of the model: the temporary one, with a previewed row in it while a scene shows.
  List<Json> get layer {
    final t = temporary;
    if (t == null) return const [];
    final preview = _preview;
    return preview == null ? t : withRecord(t, preview['record'] as Json, preview['appearance'] as Json);
  }

  /// [records] with [target]'s key set to [appearance] (merged into what is there), or removed for an empty one (Clear).
  static List<Json> withRecord(List<Json> records, Json target, Json appearance) {
    final key = overrideKey(target);
    final out = <Json>[];
    var merged = <String, dynamic>{};
    for (final r in records) {
      if (overrideKey(r) == key) {
        merged = Map<String, dynamic>.from(r['appearance'] as Map);
      } else {
        out.add(r);
      }
    }
    if (appearance.isNotEmpty) {
      merged.addAll(appearance);
      out.add({...target, 'appearance': merged});
    }
    return out;
  }

  /// What the instance at [path] shows (`[]` = the root's own bodies) for the faces of its bodies ([faces]): its whole
  /// appearance and, when the faces don't all look the same, one per face. Empty when the instance isn't in the model.
  InstanceLook lookOf(List<String> path, List<(String, int)> faces) {
    final m = _shownModel;
    if (root.isEmpty || instanceChain(m, root, path) == null) return const InstanceLook();
    final whole = resolveAppearance(m, root, path, sceneOverrides: layer);
    if (faces.isEmpty) return InstanceLook(whole: whole);
    final byFace = resolveFaces(m, root, path, faces, sceneOverrides: layer);
    final first = byFace.values.first;
    final uniform = byFace.values.every((f) => _same(f, first));
    return InstanceLook(whole: uniform ? first : whole, faces: uniform ? null : byFace);
  }

  static bool _same(Json a, Json b) => a.length == b.length && a.keys.every((k) => b[k] == a[k]);

  /// What one face (or, with no body, the instance as a whole) shows now, preview and scene included.
  Json resolvedAt(List<String> path, {String? bodyId, int? faceIndex}) =>
      resolveAppearance(_shownModel, root, path, bodyId: bodyId, faceIndex: faceIndex, sceneOverrides: layer);

  // --- the rows of the paint list ---------------------------------------------------------------------------------

  /// What a paint on the face [faceIndex] of body [bodyId] of the instance [path] offers, innermost first: Face, Body,
  /// Part, Pattern (all N), `Every <part> (N)`, each sub-assembly it sits in, Whole assembly. [instances]: every placed
  /// instance's path in the root (what a row covers).
  List<PaintRow> rowsFor(List<String> path, {String? bodyId, int? faceIndex, required List<List<String>> instances}) {
    final pathText = path.join('/');
    final rows = <(String, String, Json, List<String>)>[];
    if (bodyId != null && faceIndex != null) {
      rows.add(('face', 'Face', {'path': pathText, 'body_id': bodyId, 'face': {'body_id': bodyId, 'shape_type': 'face', 'index': faceIndex}}, [pathText]));
    }
    if (bodyId != null) rows.add(('body', 'Body', {'path': pathText, 'body_id': bodyId}, [pathText]));
    final chain = instanceChain(_model, root, path);
    if (path.isNotEmpty && chain != null) {
      final leaf = chain.last;
      rows.add(('part', 'Part · ${partName(leaf)}', {'path': pathText}, [pathText]));
      rows.addAll(_patternRows(path, chain, instances));
      final placements = [
        for (final p in instances)
          if (p.isNotEmpty && (instanceChain(_model, root, p)?.last == leaf)) p.join('/'),
      ];
      if (placements.length > 1) {
        rows.add(('same_part', 'Every ${partName(leaf)} (${placements.length})', {'path': '', 'scope': kScopeSamePart, 'part_id': leaf}, placements));
      }
      for (var d = path.length - 1; d > 0; d--) {
        final prefix = path.sublist(0, d);
        final members = [
          for (final p in instances)
            if (_startsWith(p, prefix)) p.join('/'),
        ];
        rows.add(('sub_$d', '${partName(chain[d])} (${members.length} parts)', {'path': prefix.join('/')}, members));
      }
    }
    rows.add(('whole', 'Whole assembly', {'path': ''}, [for (final p in instances) p.join('/')]));
    final list = _ownList();
    return [
      for (final (id, label, record, members) in rows)
        () {
          final own = _ownOf(list, record);
          return PaintRow(
            id: id,
            label: label,
            record: record,
            members: members,
            setHere: own != null,
            swatch: own ?? resolvedAt(path, bodyId: bodyId, faceIndex: faceIndex),
          );
        }(),
    ];
  }

  static bool _startsWith(List<String> path, List<String> prefix) {
    if (path.length < prefix.length) return false;
    for (var i = 0; i < prefix.length; i++) {
      if (path[i] != prefix[i]) return false;
    }
    return true;
  }

  List<(String, String, Json, List<String>)> _patternRows(List<String> path, List<String> chain, List<List<String>> instances) {
    final out = <(String, String, Json, List<String>)>[];
    final last = path.last;
    final source = baseSegment(last);
    final owner = chain[chain.length - 2];
    final prefix = path.sublist(0, path.length - 1);
    for (final pattern in _patterns[owner] ?? const <ComponentPatternDto>[]) {
      if (pattern.suppressed || !pattern.sourceOccurrenceIds.contains(source)) continue;
      final copyPrefix = '$source$kPatternSegment${pattern.id}:';
      if (last != source && !last.startsWith(copyPrefix)) continue;
      final copies = <String>{};
      final members = <String>[];
      for (final p in instances) {
        if (p.length < path.length || !_startsWith(p, prefix)) continue;
        final seg = p[prefix.length];
        if (seg == source || seg.startsWith(copyPrefix)) {
          copies.add(seg);
          members.add(p.join('/'));
        }
      }
      out.add(('pattern_${pattern.id}', 'Pattern (all ${copies.length})',
          {'path': [...prefix, source].join('/'), 'scope': kScopePattern, 'pattern_id': pattern.id}, members));
    }
    return out;
  }

  List<Json> _ownList() {
    final real = ((_parts[root] as Map?)?['appearance_overrides'] as List?)?.cast<Json>() ?? const <Json>[];
    return temporary == null ? real : [...real, ...temporary!];
  }

  static Json? _ownOf(List<Json> list, Json record) {
    final key = overrideKey(record);
    Json? own;
    for (final r in list) {
      if (overrideKey(r) == key) own = Map<String, dynamic>.from(r['appearance'] as Map);
    }
    return own;
  }

  // --- preview and paint ------------------------------------------------------------------------------------------

  /// Shows what painting [row] with [brush] would do (nothing sent). An empty brush previews Clear.
  void preview(PaintRow row, Json brush) {
    _preview = {'record': row.record, 'appearance': Map<String, dynamic>.from(brush)};
    notifyListeners();
  }

  void endPreview() {
    if (_preview == null) return;
    _preview = null;
    notifyListeners();
  }

  /// The appearance [row] has of its own now (null: none), for undo.
  Json? ownAppearance(PaintRow row) => _ownOf(_ownList(), row.record);

  /// Paints [row] with [brush] (merged into the row's own paint; an empty brush clears it). While a scene shows it goes
  /// into the [temporary] layer; else it is sent. Returns the appearance the row had of its own before (null: none), which
  /// `store(row.record, before)` puts back (undo).
  Future<Json?> paint(PaintRow row, Json brush) async {
    _preview = null;
    final before = ownAppearance(row);
    Json? after;
    if (brush.isNotEmpty) after = {...?before, ...brush};
    await store(row.record, after);
    return before;
  }

  /// Sets [record]'s own override to [appearance] (null clears): in the temporary layer while a scene shows, else on the
  /// backend (the model takes the backend's list back).
  Future<void> store(Json record, Json? appearance) async {
    final t = temporary;
    if (t != null) {
      final key = overrideKey(record);
      temporary = [
        for (final r in t)
          if (overrideKey(r) != key) r,
        if (appearance != null) {...record, 'appearance': appearance},
      ];
      notifyListeners();
      return;
    }
    final body = <String, dynamic>{...record, 'appearance': appearance};
    final listed = await api.putAppearanceOverride(root, body);
    final entry = Map<String, dynamic>.from((_parts[root] as Map?) ?? {'occurrences': <String, dynamic>{}});
    _setOverrides(entry, listed);
    _mirrorLegacy(entry, record, appearance);
    _parts[root] = entry;
    notifyListeners();
  }

  /// The backend mirrors a top-level occurrence's own colour into `Occurrence.color` (and clears it with the override): the
  /// model's copy follows, so the legacy alias doesn't bring back a cleared colour.
  static void _mirrorLegacy(Json entry, Json record, Json? appearance) {
    final path = (record['path'] as String?) ?? '';
    if (path.isEmpty || path.contains('/') || path.contains('#') || record.length != 1) return;
    final occ = (entry['occurrences'] as Map?)?[path];
    if (occ is! Map) return;
    if (appearance == null) {
      occ['color'] = null;
    } else if (appearance['colour'] != null) {
      occ['color'] = appearance['colour'];
    }
  }
}
