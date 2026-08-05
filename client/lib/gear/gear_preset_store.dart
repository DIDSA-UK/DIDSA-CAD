import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

/// `docs/gear-design/09-presets.md`: a named snapshot of one Gear Design
/// screen's own form state - [kind] discriminates which screen/gear type
/// it was captured from (`'gear_design'` for [GearDesignScreen]'s
/// external/internal/rack/helical form, `'gear_chain_design'` for
/// [GearChainDesignScreen]'s chain/planetary form, `'bevel_design'` for
/// [BevelDesignScreen]'s bevel gear/pair form) so the picker only ever
/// offers presets that actually fit the screen asking for one. [fields] is
/// a plain, screen-defined `{fieldName: value}` map - this store has no
/// opinion on what a preset holds, only on persisting/listing/deleting it
/// (`00-conventions.md`'s "reusable, not reinvented per screen" spirit,
/// applied to client-local storage the same way `SketcherPreferences`/
/// `MeshViewerPreferences` already established for scalar settings).
///
/// **Convenience for re-populating a form, not a live link** - per that
/// doc's own explicit note, loading a preset and creating a gear produces
/// an ordinary, independent Feature with no ongoing relationship to the
/// preset it came from. Nothing here is ever read by the backend.
class GearPreset {
  final String id;
  final String name;
  final String kind;
  final Map<String, dynamic> fields;
  final DateTime createdAt;

  const GearPreset({required this.id, required this.name, required this.kind, required this.fields, required this.createdAt});

  factory GearPreset.fromJson(Map<String, dynamic> json) => GearPreset(
        id: json['id'] as String,
        name: json['name'] as String,
        kind: json['kind'] as String,
        fields: Map<String, dynamic>.from(json['fields'] as Map),
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'kind': kind,
        'fields': fields,
        'created_at': createdAt.toIso8601String(),
      };
}

/// `docs/gear-design/09-presets.md`'s own explicit resolution: **client-
/// local** storage (this app's backend "persists no model data" boundary,
/// `docs/project-brief.md` §3, stays intact), the same `shared_preferences`
/// mechanism `SketcherPreferences`/`MeshViewerPreferences` already use -
/// just one JSON-encoded list under a single key rather than scalar values,
/// since a preset store's own shape (a named, growable collection) is
/// genuinely different from either of those classes' own "one persisted
/// default" shape.
class GearPresetStore {
  GearPresetStore._();

  static const String _prefKey = 'gear_design_presets';

  static List<GearPreset> _presets = [];
  static final Random _idRandom = Random();

  static List<GearPreset> get all => List.unmodifiable(_presets);

  static List<GearPreset> forKind(String kind) => _presets.where((p) => p.kind == kind).toList(growable: false);

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) {
      _presets = [];
      return;
    }
    try {
      final decoded = jsonDecode(raw) as List;
      _presets = decoded.map((e) => GearPreset.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      // Corrupt/unreadable stored value (e.g. from a future, incompatible
      // app version) - fail open to an empty list rather than crashing the
      // whole screen on load, same "don't let stale local state break the
      // app" spirit every other *Preferences class's own defensive
      // `orElse`/`??` fallback already follows.
      _presets = [];
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_presets.map((p) => p.toJson()).toList()));
  }

  static Future<GearPreset> save(String name, String kind, Map<String, dynamic> fields) async {
    final preset = GearPreset(
      id: '${DateTime.now().microsecondsSinceEpoch}-${_idRandom.nextInt(1 << 32)}',
      name: name,
      kind: kind,
      fields: fields,
      createdAt: DateTime.now(),
    );
    _presets = [..._presets, preset];
    await _persist();
    return preset;
  }

  static Future<void> delete(String id) async {
    _presets = _presets.where((p) => p.id != id).toList();
    await _persist();
  }
}
