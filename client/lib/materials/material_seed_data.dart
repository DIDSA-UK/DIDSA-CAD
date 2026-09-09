import 'material.dart';

/// Starter material library, seeded into [MaterialStore] the first time it
/// ever loads on a fresh install so the Materials Manager/picker isn't
/// empty. Values are drawn from general engineering reference knowledge
/// (approximate, typical-condition figures - e.g. "6061-T6", "304 annealed")
/// rather than pulled from a single live datasheet in this session -
/// **double-check these against a trusted materials reference (e.g.
/// MatWeb) before relying on them for real engineering decisions**, since a
/// wrong density is a silent mass-calculation bug. `null` marks a property
/// this app has no confident typical value for (e.g. cast iron's yield
/// strength - grey iron is brittle and has no well-defined yield point).
List<Material> buildSeedMaterials(DateTime now) {
  Material m(
    String name,
    String category,
    double density, {
    double? e,
    double? poisson,
    double? yieldMpa,
    double? tensileMpa,
    double? shearGPa,
    double? cte,
    double? k,
    double? cp,
  }) =>
      Material(
        id: 'seed-${name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-')}',
        name: name,
        category: category,
        densityGCm3: density,
        elasticModulusGPa: e,
        poissonsRatio: poisson,
        yieldStrengthMPa: yieldMpa,
        tensileStrengthMPa: tensileMpa,
        shearModulusGPa: shearGPa,
        thermalExpansionPerK: cte,
        thermalConductivityWmK: k,
        specificHeatJKgK: cp,
        isBuiltIn: true,
        createdAt: now,
      );

  const plastic = 'Plastic';
  const carbonSteel = 'Carbon Steel';
  const stainless = 'Stainless Steel';
  const aluminum = 'Aluminum Alloy';
  const engineering = 'Engineering Alloy';

  return [
    // Plastics
    m('ABS', plastic, 1.05, e: 2.3, poisson: 0.35, yieldMpa: 40, tensileMpa: 40, cte: 90e-6, k: 0.17, cp: 1386),
    m('PLA', plastic, 1.24, e: 3.5, poisson: 0.36, yieldMpa: 50, tensileMpa: 50, cte: 68e-6, k: 0.13, cp: 1800),
    m('Nylon 6/6', plastic, 1.14, e: 2.9, poisson: 0.39, yieldMpa: 45, tensileMpa: 75, shearGPa: 1.0, cte: 80e-6, k: 0.25, cp: 1670),
    m('Polycarbonate', plastic, 1.20, e: 2.4, poisson: 0.37, yieldMpa: 62, tensileMpa: 65, shearGPa: 0.88, cte: 65e-6, k: 0.19, cp: 1200),
    m('HDPE', plastic, 0.95, e: 1.0, poisson: 0.42, yieldMpa: 26, tensileMpa: 30, shearGPa: 0.35, cte: 200e-6, k: 0.48, cp: 1900),
    m('POM (Delrin)', plastic, 1.41, e: 2.8, poisson: 0.35, yieldMpa: 65, tensileMpa: 70, shearGPa: 1.0, cte: 110e-6, k: 0.31, cp: 1470),
    m('PETG', plastic, 1.27, e: 2.1, poisson: 0.38, yieldMpa: 50, tensileMpa: 53, shearGPa: 0.76, cte: 68e-6, k: 0.29, cp: 1200),

    // Carbon/structural steels
    m('AISI 1018 Steel', carbonSteel, 7.87, e: 205, poisson: 0.29, yieldMpa: 370, tensileMpa: 440, shearGPa: 79.3, cte: 11.5e-6, k: 51.9, cp: 486),
    m('AISI 1045 Steel', carbonSteel, 7.85, e: 200, poisson: 0.29, yieldMpa: 450, tensileMpa: 625, shearGPa: 80, cte: 11.2e-6, k: 49.8, cp: 486),
    m('ASTM A36 Steel', carbonSteel, 7.85, e: 200, poisson: 0.26, yieldMpa: 250, tensileMpa: 400, shearGPa: 79.3, cte: 11.7e-6, k: 51.9, cp: 486),

    // Stainless steels
    m('Stainless Steel 304', stainless, 8.00, e: 193, poisson: 0.29, yieldMpa: 215, tensileMpa: 505, shearGPa: 75, cte: 17.2e-6, k: 16.2, cp: 500),
    m('Stainless Steel 316', stainless, 8.00, e: 193, poisson: 0.29, yieldMpa: 205, tensileMpa: 515, shearGPa: 75, cte: 16.0e-6, k: 16.3, cp: 500),
    m('Stainless Steel 17-4PH', stainless, 7.75, e: 196, poisson: 0.27, yieldMpa: 1170, tensileMpa: 1310, shearGPa: 77, cte: 10.8e-6, k: 18.0, cp: 460),

    // Aluminum alloys
    m('Aluminum 6061-T6', aluminum, 2.70, e: 68.9, poisson: 0.33, yieldMpa: 276, tensileMpa: 310, shearGPa: 26, cte: 23.6e-6, k: 167, cp: 896),
    m('Aluminum 7075-T6', aluminum, 2.81, e: 71.7, poisson: 0.33, yieldMpa: 503, tensileMpa: 572, shearGPa: 26.9, cte: 23.6e-6, k: 130, cp: 960),
    m('Aluminum 2024-T3', aluminum, 2.78, e: 73.1, poisson: 0.33, yieldMpa: 345, tensileMpa: 483, shearGPa: 28, cte: 23.2e-6, k: 121, cp: 875),
    m('Aluminum A356-T6 (Cast)', aluminum, 2.68, e: 72.4, poisson: 0.33, yieldMpa: 186, tensileMpa: 228, shearGPa: 27, cte: 21.5e-6, k: 151, cp: 963),

    // Other engineering alloys
    m('Titanium Ti-6Al-4V', engineering, 4.43, e: 113.8, poisson: 0.342, yieldMpa: 880, tensileMpa: 950, shearGPa: 44, cte: 8.6e-6, k: 6.7, cp: 526),
    m('Brass C360', engineering, 8.50, e: 97, poisson: 0.34, yieldMpa: 130, tensileMpa: 340, shearGPa: 37, cte: 20.5e-6, k: 115, cp: 380),
    m('Bronze C932', engineering, 8.64, e: 103, poisson: 0.34, yieldMpa: 125, tensileMpa: 240, shearGPa: 38, cte: 18.0e-6, k: 45, cp: 380),
    m('Copper C110', engineering, 8.94, e: 117, poisson: 0.34, yieldMpa: 69, tensileMpa: 220, shearGPa: 44, cte: 17.0e-6, k: 391, cp: 385),
    m('Grey Cast Iron (ASTM A48)', engineering, 7.15, e: 100, poisson: 0.26, tensileMpa: 214, shearGPa: 40, cte: 11.0e-6, k: 47, cp: 490),
  ];
}
