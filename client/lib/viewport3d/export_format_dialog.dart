import 'package:flutter/material.dart';

/// One selectable entry in [showExportFormatDialog] - [label] is what the
/// user sees, [value] is both the backend's own `GET /export/{format}`
/// path segment and the saved file's extension (`DocumentApiClient.exportPart`).
class ExportFormatOption {
  final String label;
  final String value;

  const ExportFormatOption({required this.label, required this.value});
}

/// On-device request: the File menu's four format-specific export entries
/// folded into one "Export…" entry, this dialog as its first step -
/// mirrors [showImportFormatDialog]'s own shape (`import_format_dialog.dart`)
/// for the opposite direction.
const List<ExportFormatOption> exportFormatOptions = [
  ExportFormatOption(label: 'STEP', value: 'step'),
  ExportFormatOption(label: 'STL', value: 'stl'),
  ExportFormatOption(label: 'OBJ', value: 'obj'),
  ExportFormatOption(label: 'glTF', value: 'glb'),
];

/// Prompts for which format to export, returning the chosen
/// [ExportFormatOption.value] or `null` if the user cancelled (tapped
/// outside, back gesture) - `PartScreen._exportPart` treats `null` as "do
/// nothing" and never reaches the folder/filename picker in that case.
Future<String?> showExportFormatDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Export'),
      children: [
        for (final option in exportFormatOptions)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(option.value),
            child: Text(option.label),
          ),
      ],
    ),
  );
}
