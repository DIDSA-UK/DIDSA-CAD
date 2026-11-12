/// F-6 (`docs/iges-jt-and-desktop-input-plan-2026-11-11.md`): the answers of `POST /document/import/probe` and the two assembly-import endpoints.
library;

/// What a STEP / IGES file holds, read without importing it (`POST /document/import/probe`).
class ImportProbeDto {
  final int products;
  final int assemblies;
  final int instances;
  final bool hasStructure;
  final int mirroredInstances;
  final String name;

  const ImportProbeDto({
    required this.products,
    required this.assemblies,
    required this.instances,
    required this.hasStructure,
    required this.mirroredInstances,
    required this.name,
  });

  factory ImportProbeDto.fromJson(Map<String, dynamic> json) => ImportProbeDto(
        products: (json['products'] as num?)?.toInt() ?? 0,
        assemblies: (json['assemblies'] as num?)?.toInt() ?? 0,
        instances: (json['instances'] as num?)?.toInt() ?? 0,
        hasStructure: json['has_structure'] as bool? ?? false,
        mirroredInstances: (json['mirrored_instances'] as num?)?.toInt() ?? 0,
        name: json['name'] as String? ?? '',
      );
}

/// One product an assembly import left out, and why.
class ImportSkipDto {
  final String name;
  final String reason;

  const ImportSkipDto({required this.name, required this.reason});

  factory ImportSkipDto.fromJson(Map<String, dynamic> json) =>
      ImportSkipDto(name: json['name'] as String? ?? '', reason: json['reason'] as String? ?? '');
}

/// The per-part report: "35 of 37 parts imported; 2 skipped: ...".
class ImportAssemblyReportDto {
  final int imported;
  final int total;
  final List<ImportSkipDto> skipped;
  final int baked;

  const ImportAssemblyReportDto({required this.imported, required this.total, required this.skipped, required this.baked});

  factory ImportAssemblyReportDto.fromJson(Map<String, dynamic> json) => ImportAssemblyReportDto(
        imported: (json['imported'] as num?)?.toInt() ?? 0,
        total: (json['total'] as num?)?.toInt() ?? 0,
        skipped: [for (final s in (json['skipped'] as List? ?? const [])) ImportSkipDto.fromJson(s as Map<String, dynamic>)],
        baked: (json['baked'] as num?)?.toInt() ?? 0,
      );

  /// One line for a snackbar or dialog.
  String get summary {
    final base = '$imported of $total ${total == 1 ? 'part' : 'parts'} imported';
    if (skipped.isEmpty) return base;
    final names = skipped.map((s) => '${s.name} (${s.reason})').join(', ');
    return '$base; ${skipped.length} skipped: $names';
  }
}

/// What an assembly import hands back: the new Parts and the file suggested for each (relative to the project root, "folder/File.didsa").
class ImportAssemblyDto {
  final List<String> newPartIds;
  final String rootPartId;
  final String? occurrenceId;
  final String folder;
  final Map<String, String> suggestedFiles;
  final ImportAssemblyReportDto report;

  const ImportAssemblyDto({
    required this.newPartIds,
    required this.rootPartId,
    required this.occurrenceId,
    required this.folder,
    required this.suggestedFiles,
    required this.report,
  });

  factory ImportAssemblyDto.fromJson(Map<String, dynamic> json) => ImportAssemblyDto(
        newPartIds: [for (final id in (json['new_part_ids'] as List? ?? const [])) id as String],
        rootPartId: json['root_part_id'] as String,
        occurrenceId: json['occurrence_id'] as String?,
        folder: json['folder'] as String? ?? '',
        suggestedFiles: {
          for (final e in ((json['suggested_files'] as Map?) ?? const {}).entries) e.key as String: e.value as String,
        },
        report: ImportAssemblyReportDto.fromJson((json['report'] as Map?)?.cast<String, dynamic>() ?? const {}),
      );
}
