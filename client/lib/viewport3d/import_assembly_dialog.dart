import 'package:material_ui/material_ui.dart';

import '../api/import_assembly_dto.dart';

/// F-6: the second step of a STEP / IGES import - the file is one part, or an assembly (STEP) / one part per solid (IGES).
enum ImportAssemblyChoice { assembly, onePart }

/// The default for a file with [probe]'s contents: an assembly when it holds more than one product (STEP) or more than one solid (IGES), else one part.
ImportAssemblyChoice defaultImportChoice(ImportProbeDto probe) =>
    probe.products > 1 || probe.assemblies > 0 ? ImportAssemblyChoice.assembly : ImportAssemblyChoice.onePart;

/// Whether this import offers the choice at all: a single product (one body, no structure) imports as one part with no question.
bool offersAssemblyChoice(ImportProbeDto probe) => probe.products > 1 || probe.assemblies > 0;

/// "This file has 37 parts in 6 sub-assemblies" / "This file has 12 solids".
String importProbeSummary(ImportProbeDto probe, String sourceFormat) {
  if (sourceFormat == 'iges') {
    return 'This file has ${probe.products} ${probe.products == 1 ? 'solid' : 'solids'}.';
  }
  final parts = '${probe.products} ${probe.products == 1 ? 'part' : 'parts'}';
  if (probe.assemblies == 0) return 'This file has $parts.';
  return 'This file has $parts in ${probe.assemblies} ${probe.assemblies == 1 ? 'sub-assembly' : 'sub-assemblies'}.';
}

/// The wording of the "as an assembly" option (IGES has no product structure: one part per solid).
String assemblyOptionLabel(String sourceFormat) => sourceFormat == 'iges' ? 'One part per solid' : 'As an assembly';

/// Asks how to import: returns the choice, or null if the user cancelled.
Future<ImportAssemblyChoice?> showImportAssemblyDialog(BuildContext context, ImportProbeDto probe, String sourceFormat) {
  final defaultChoice = defaultImportChoice(probe);
  return showDialog<ImportAssemblyChoice>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Import as'),
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(24, 0, 24, 12),
          child: Text(importProbeSummary(probe, sourceFormat), key: const ValueKey('import-probe-summary')),
        ),
        SimpleDialogOption(
          key: const ValueKey('import-as-assembly'),
          onPressed: () => Navigator.of(context).pop(ImportAssemblyChoice.assembly),
          child: Text('${assemblyOptionLabel(sourceFormat)}${defaultChoice == ImportAssemblyChoice.assembly ? '  (suggested)' : ''}'),
        ),
        SimpleDialogOption(
          key: const ValueKey('import-as-one-part'),
          onPressed: () => Navigator.of(context).pop(ImportAssemblyChoice.onePart),
          child: Text('As one part${defaultChoice == ImportAssemblyChoice.onePart ? '  (suggested)' : ''}'),
        ),
      ],
    ),
  );
}
