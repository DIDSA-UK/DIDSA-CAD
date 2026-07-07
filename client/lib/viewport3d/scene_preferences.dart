import 'package:shared_preferences/shared_preferences.dart';

/// Single source of truth for the material/lighting appearance controls
/// introduced alongside the `PhysicallyBasedMaterial` rendering upgrade (see
/// `mesh_geometry.dart`/`mesh_viewer_render.dart`) - the same
/// `shared_preferences`-backed, load-then-read-getters pattern
/// [ViewPreferences] already uses, so both the main Part viewport and the
/// standalone mesh viewer read/write the *same* stored settings.
///
/// Base colour ("shading") deliberately isn't duplicated here - it reuses
/// [ViewPreferences.bodyColourHex] (the pre-existing "Body Colour" picker),
/// since a PBR material's base colour and the old flat `UnlitMaterial`'s
/// tint are the same underlying concept, just rendered differently now.
/// [ViewPreferences.defaultBodyColourHex] was changed to mid-grey (`#808080`)
/// alongside this class's introduction, per the user's explicit requested
/// default for the new Scene menu - anyone with an existing stored value
/// keeps it (same non-destructive-default convention [ViewPreferences]
/// already documents for its own past default changes).
///
/// `metallic` is fixed at [fixedMetallic] (non-metal/plastic) rather than
/// exposed as a slider - the user asked for "shading, texture, lighting,
/// luminescence", which this maps to base colour/roughness/light
/// intensity/emissive; metallic wasn't one of the four, so it isn't a fifth
/// control here. A constant ambient/IBL fill (`EnvironmentMap.studio()` -
/// see the rendering code) is always applied unconditionally so the unlit
/// side of a Body isn't pure black; there's no separate "ambient" control
/// here for the same reason - it's baseline behaviour, not user-adjustable.
class ScenePreferences {
  ScenePreferences._();

  static const String roughnessPrefKey = 'scene_roughness';
  static const String lightIntensityPrefKey = 'scene_light_intensity';
  static const String emissiveIntensityPrefKey = 'scene_emissive_intensity';

  /// "Light roughness" per the user's explicit requested default - fairly
  /// smooth (a soft, readable specular highlight) without being mirror-like.
  static const double defaultRoughness = 0.35;

  /// Non-metal/plastic - not user-adjustable, see this class's own doc
  /// comment for why.
  static const double fixedMetallic = 0.0;

  /// "Mid lighting" per the user's explicit requested default.
  /// `DirectionalLight`'s own default intensity is 3.0 (per the real
  /// `flutter_scene` source) - `1.5` is that scaled to a "mid" slider
  /// position on a 0.0-3.0 range.
  static const double defaultLightIntensity = 1.5;
  static const double maxLightIntensity = 3.0;

  /// "Luminescence" - off by default (the user named this as an available
  /// control, not one of the three explicit defaults), 0.0-1.0 range.
  static const double defaultEmissiveIntensity = 0.0;

  static double _roughness = defaultRoughness;
  static double _lightIntensity = defaultLightIntensity;
  static double _emissiveIntensity = defaultEmissiveIntensity;

  static double get roughness => _roughness;
  static double get lightIntensity => _lightIntensity;
  static double get emissiveIntensity => _emissiveIntensity;

  static Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    _roughness = prefs.getDouble(roughnessPrefKey) ?? defaultRoughness;
    _lightIntensity = prefs.getDouble(lightIntensityPrefKey) ?? defaultLightIntensity;
    _emissiveIntensity = prefs.getDouble(emissiveIntensityPrefKey) ?? defaultEmissiveIntensity;
  }

  static Future<void> setRoughness(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(roughnessPrefKey, value);
    _roughness = value;
  }

  static Future<void> setLightIntensity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(lightIntensityPrefKey, value);
    _lightIntensity = value;
  }

  static Future<void> setEmissiveIntensity(double value) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(emissiveIntensityPrefKey, value);
    _emissiveIntensity = value;
  }
}
