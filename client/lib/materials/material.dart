/// A material library entry - name plus density (mandatory) and a
/// SolidWorks-style set of stress-analysis fields (all optional, since not
/// every material - especially a user's own hand-added one - will have
/// every property on hand). Client-local only: the backend never sees this
/// full shape, only a resolved `(materialId, name, densityGCm3)` assignment
/// (see `MaterialAssignment`/`material_assignment.dart`) - the 8 stress
/// fields below matter only for a possible future stress-analysis feature,
/// not for mass calculation or STEP export, so there is no reason for the
/// backend to know about them at all.
///
/// Density is stored in g/cm^3 - the unit essentially every published
/// material datasheet and SolidWorks' own material library use (steel 7.85,
/// 6061 aluminum 2.70, ABS 1.05), easiest for a user to type in directly via
/// the Add Material form. The one mass formula that consumes this
/// (`mass_g = volume_mm3 * density_g_cm3 * 0.001`) lives on the backend
/// (`app.document.measure._mass_grams`) since mass is always computed from
/// geometry the backend already holds.
class CadMaterial {
  final String id;
  final String name;
  final String category;
  final double densityGCm3;
  final double? elasticModulusGPa;
  final double? poissonsRatio;
  final double? yieldStrengthMPa;
  final double? tensileStrengthMPa;
  final double? shearModulusGPa;
  final double? thermalExpansionPerK;
  final double? thermalConductivityWmK;
  final double? specificHeatJKgK;

  /// Seeded default vs user-added - gates delete/edit in the Materials
  /// Manager (a built-in can still be edited, but is protected from
  /// accidental deletion; see `MaterialStore.resetToDefaults` for the
  /// escape hatch if a built-in was edited into something unwanted).
  final bool isBuiltIn;
  final DateTime createdAt;

  const CadMaterial({
    required this.id,
    required this.name,
    required this.category,
    required this.densityGCm3,
    this.elasticModulusGPa,
    this.poissonsRatio,
    this.yieldStrengthMPa,
    this.tensileStrengthMPa,
    this.shearModulusGPa,
    this.thermalExpansionPerK,
    this.thermalConductivityWmK,
    this.specificHeatJKgK,
    required this.isBuiltIn,
    required this.createdAt,
  });

  CadMaterial copyWith({
    String? name,
    String? category,
    double? densityGCm3,
    double? elasticModulusGPa,
    double? poissonsRatio,
    double? yieldStrengthMPa,
    double? tensileStrengthMPa,
    double? shearModulusGPa,
    double? thermalExpansionPerK,
    double? thermalConductivityWmK,
    double? specificHeatJKgK,
    bool? isBuiltIn,
  }) {
    return CadMaterial(
      id: id,
      name: name ?? this.name,
      category: category ?? this.category,
      densityGCm3: densityGCm3 ?? this.densityGCm3,
      elasticModulusGPa: elasticModulusGPa ?? this.elasticModulusGPa,
      poissonsRatio: poissonsRatio ?? this.poissonsRatio,
      yieldStrengthMPa: yieldStrengthMPa ?? this.yieldStrengthMPa,
      tensileStrengthMPa: tensileStrengthMPa ?? this.tensileStrengthMPa,
      shearModulusGPa: shearModulusGPa ?? this.shearModulusGPa,
      thermalExpansionPerK: thermalExpansionPerK ?? this.thermalExpansionPerK,
      thermalConductivityWmK: thermalConductivityWmK ?? this.thermalConductivityWmK,
      specificHeatJKgK: specificHeatJKgK ?? this.specificHeatJKgK,
      isBuiltIn: isBuiltIn ?? this.isBuiltIn,
      createdAt: createdAt,
    );
  }

  factory CadMaterial.fromJson(Map<String, dynamic> json) => CadMaterial(
        id: json['id'] as String,
        name: json['name'] as String,
        category: json['category'] as String,
        densityGCm3: (json['density_g_cm3'] as num).toDouble(),
        elasticModulusGPa: (json['elastic_modulus_gpa'] as num?)?.toDouble(),
        poissonsRatio: (json['poissons_ratio'] as num?)?.toDouble(),
        yieldStrengthMPa: (json['yield_strength_mpa'] as num?)?.toDouble(),
        tensileStrengthMPa: (json['tensile_strength_mpa'] as num?)?.toDouble(),
        shearModulusGPa: (json['shear_modulus_gpa'] as num?)?.toDouble(),
        thermalExpansionPerK: (json['thermal_expansion_per_k'] as num?)?.toDouble(),
        thermalConductivityWmK: (json['thermal_conductivity_w_mk'] as num?)?.toDouble(),
        specificHeatJKgK: (json['specific_heat_j_kgk'] as num?)?.toDouble(),
        isBuiltIn: json['is_built_in'] as bool? ?? false,
        createdAt: DateTime.parse(json['created_at'] as String),
      );

  Map<String, dynamic> toJson() => {
        'id': id,
        'name': name,
        'category': category,
        'density_g_cm3': densityGCm3,
        'elastic_modulus_gpa': elasticModulusGPa,
        'poissons_ratio': poissonsRatio,
        'yield_strength_mpa': yieldStrengthMPa,
        'tensile_strength_mpa': tensileStrengthMPa,
        'shear_modulus_gpa': shearModulusGPa,
        'thermal_expansion_per_k': thermalExpansionPerK,
        'thermal_conductivity_w_mk': thermalConductivityWmK,
        'specific_heat_j_kgk': specificHeatJKgK,
        'is_built_in': isBuiltIn,
        'created_at': createdAt.toIso8601String(),
      };
}
