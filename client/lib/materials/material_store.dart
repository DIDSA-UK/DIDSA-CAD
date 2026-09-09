import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

import 'material.dart';
import 'material_seed_data.dart';

/// Client-local material library - same `shared_preferences`-backed,
/// one-JSON-list-under-one-key persistence shape as `GearPresetStore`
/// (`client/lib/gear/gear_preset_store.dart`), extended with `update` (the
/// Materials Manager needs real edit, unlike a GearPreset) and
/// `resetToDefaults` (an escape hatch if a built-in material was edited
/// into something unwanted). Never read by the backend - only a resolved
/// `(materialId, name, densityGCm3)` assignment reaches the backend, via
/// `MaterialAssignment`.
class MaterialStore {
  MaterialStore._();

  static const String _prefKey = 'material_library';

  static List<CadMaterial> _materials = [];
  static final Random _idRandom = Random();

  static List<CadMaterial> get all => List.unmodifiable(_materials);

  static CadMaterial? byId(String id) {
    for (final material in _materials) {
      if (material.id == id) return material;
    }
    return null;
  }

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    final raw = prefs.getString(_prefKey);
    if (raw == null || raw.isEmpty) {
      // Fresh install (or the key has never been written) - seed the
      // starter library so the Manager/picker isn't empty on first use.
      _materials = buildSeedMaterials(DateTime.now());
      await _persist();
      return;
    }
    try {
      final decoded = jsonDecode(raw) as List;
      _materials = decoded.map((e) => CadMaterial.fromJson(e as Map<String, dynamic>)).toList();
    } catch (_) {
      // Corrupt/unreadable stored value - fail open to the seed set rather
      // than crashing the whole screen on load, same "don't let stale local
      // state break the app" spirit every other *Store/*Preferences class's
      // own defensive fallback already follows.
      _materials = buildSeedMaterials(DateTime.now());
    }
  }

  static Future<void> _persist() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefKey, jsonEncode(_materials.map((m) => m.toJson()).toList()));
  }

  static Future<CadMaterial> add(CadMaterial material) async {
    final withId = material.id.isEmpty
        ? CadMaterial(
            id: '${DateTime.now().microsecondsSinceEpoch}-${_idRandom.nextInt(1 << 32)}',
            name: material.name,
            category: material.category,
            densityGCm3: material.densityGCm3,
            elasticModulusGPa: material.elasticModulusGPa,
            poissonsRatio: material.poissonsRatio,
            yieldStrengthMPa: material.yieldStrengthMPa,
            tensileStrengthMPa: material.tensileStrengthMPa,
            shearModulusGPa: material.shearModulusGPa,
            thermalExpansionPerK: material.thermalExpansionPerK,
            thermalConductivityWmK: material.thermalConductivityWmK,
            specificHeatJKgK: material.specificHeatJKgK,
            isBuiltIn: false,
            createdAt: DateTime.now(),
          )
        : material;
    _materials = [..._materials, withId];
    await _persist();
    return withId;
  }

  static Future<void> update(CadMaterial material) async {
    _materials = [for (final m in _materials) if (m.id == material.id) material else m];
    await _persist();
  }

  static Future<void> delete(String id) async {
    _materials = _materials.where((m) => m.id != id).toList();
    await _persist();
  }

  /// Escape hatch: re-seeds every built-in material back to its shipped
  /// values (e.g. after one was accidentally edited), leaving every
  /// user-added (`isBuiltIn: false`) material untouched.
  static Future<void> resetToDefaults() async {
    final userAdded = _materials.where((m) => !m.isBuiltIn).toList();
    _materials = [...buildSeedMaterials(DateTime.now()), ...userAdded];
    await _persist();
  }
}
