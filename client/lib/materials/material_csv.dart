import 'dart:math';

import 'package:csv/csv.dart';

import 'material.dart';

/// Column order for the Materials Manager's CSV import/export. `id`/
/// `created_at`/`is_built_in` are deliberately not columns - export omits
/// them as internal bookkeeping the user doesn't need to see/edit in a
/// spreadsheet, and import always mints a fresh, non-built-in material with
/// a new id and the current timestamp, even when re-importing a file this
/// app itself exported.
const List<String> materialCsvColumns = [
  'name',
  'category',
  'density_g_cm3',
  'elastic_modulus_gpa',
  'poissons_ratio',
  'yield_strength_mpa',
  'tensile_strength_mpa',
  'shear_modulus_gpa',
  'thermal_expansion_per_k',
  'thermal_conductivity_w_mk',
  'specific_heat_j_kgk',
];

String materialsToCsv(List<CadMaterial> materials) {
  final rows = <List<dynamic>>[
    materialCsvColumns,
    for (final m in materials)
      [
        m.name,
        m.category,
        m.densityGCm3,
        m.elasticModulusGPa ?? '',
        m.poissonsRatio ?? '',
        m.yieldStrengthMPa ?? '',
        m.tensileStrengthMPa ?? '',
        m.shearModulusGPa ?? '',
        m.thermalExpansionPerK ?? '',
        m.thermalConductivityWmK ?? '',
        m.specificHeatJKgK ?? '',
      ],
  ];
  return const ListToCsvConverter().convert(rows);
}

/// Parses `csv` into materials, skipping (and counting) any row missing a
/// required field (`name`/`category`/`density_g_cm3`) or with an
/// unparseable `density_g_cm3` - every optional numeric column left blank
/// parses to `null` rather than being treated as an error. Every imported
/// material is fresh (`isBuiltIn: false`, a new id, the current timestamp) -
/// see [materialCsvColumns]'s own doc comment for why.
({List<CadMaterial> imported, int skipped}) materialsFromCsv(String csv) {
  final rows = const CsvToListConverter(eol: '\n', shouldParseNumbers: false).convert(csv);
  if (rows.isEmpty) return (imported: const <CadMaterial>[], skipped: 0);

  final header = rows.first.map((c) => c.toString().trim().toLowerCase()).toList();
  final columnIndex = {for (var i = 0; i < header.length; i++) header[i]: i};

  String? cell(List<dynamic> row, String column) {
    final index = columnIndex[column];
    if (index == null || index >= row.length) return null;
    final value = row[index].toString().trim();
    return value.isEmpty ? null : value;
  }

  double? parseDouble(String? value) => value == null ? null : double.tryParse(value);

  final random = Random();
  final imported = <CadMaterial>[];
  var skipped = 0;

  for (final row in rows.skip(1)) {
    if (row.every((c) => c.toString().trim().isEmpty)) continue; // blank line
    final name = cell(row, 'name');
    final category = cell(row, 'category');
    final density = parseDouble(cell(row, 'density_g_cm3'));
    if (name == null || category == null || density == null) {
      skipped++;
      continue;
    }
    imported.add(CadMaterial(
      id: '${DateTime.now().microsecondsSinceEpoch}-${random.nextInt(1 << 32)}',
      name: name,
      category: category,
      densityGCm3: density,
      elasticModulusGPa: parseDouble(cell(row, 'elastic_modulus_gpa')),
      poissonsRatio: parseDouble(cell(row, 'poissons_ratio')),
      yieldStrengthMPa: parseDouble(cell(row, 'yield_strength_mpa')),
      tensileStrengthMPa: parseDouble(cell(row, 'tensile_strength_mpa')),
      shearModulusGPa: parseDouble(cell(row, 'shear_modulus_gpa')),
      thermalExpansionPerK: parseDouble(cell(row, 'thermal_expansion_per_k')),
      thermalConductivityWmK: parseDouble(cell(row, 'thermal_conductivity_w_mk')),
      specificHeatJKgK: parseDouble(cell(row, 'specific_heat_j_kgk')),
      isBuiltIn: false,
      createdAt: DateTime.now(),
    ));
  }

  return (imported: imported, skipped: skipped);
}
