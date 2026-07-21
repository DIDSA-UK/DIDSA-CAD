import 'package:flutter/material.dart';

/// One selectable entry in [showImportFormatDialog] - [label] is what the
/// user sees, [value] is the backend's own `source_format` string
/// (`DocumentApiClient.createImportFeature`/`ImportSourceFormat`), and
/// [extensions] are the file extensions this format covers (STEP has two
/// common ones) - both consumed by `PartScreen._importGeometry` to validate
/// the file the user picks next actually matches what they chose here.
class ImportFormatOption {
  final String label;
  final String value;
  final List<String> extensions;

  const ImportFormatOption({required this.label, required this.value, required this.extensions});
}

/// On-device request: the File menu's four format-specific import entries
/// (mirroring Export's own "Export STEP"/"Export STL"/... ListTiles) folded
/// into the single "Import…" entry it already had, replaced with this
/// dialog as its first step - picking a format here, then a file next,
/// rather than four separate menu rows or (the previous single-entry
/// behavior) silently guessing the format from whatever file extension the
/// user happens to pick.
const List<ImportFormatOption> importFormatOptions = [
  ImportFormatOption(label: 'STEP', value: 'step', extensions: ['step', 'stp']),
  ImportFormatOption(label: 'STL', value: 'stl', extensions: ['stl']),
  ImportFormatOption(label: 'OBJ', value: 'obj', extensions: ['obj']),
  ImportFormatOption(label: 'glTF', value: 'gltf', extensions: ['gltf', 'glb']),
];

/// Prompts for which format to import, returning the chosen
/// [ImportFormatOption.value] or `null` if the user cancelled (tapped
/// outside, back gesture) - `PartScreen._importGeometry` treats `null` as
/// "do nothing", the same convention every other dialog in this app uses.
Future<String?> showImportFormatDialog(BuildContext context) {
  return showDialog<String>(
    context: context,
    builder: (context) => SimpleDialog(
      title: const Text('Import'),
      children: [
        for (final option in importFormatOptions)
          SimpleDialogOption(
            onPressed: () => Navigator.of(context).pop(option.value),
            child: Text(option.label),
          ),
      ],
    ),
  );
}
