import 'dart:async';

import 'package:flutter/material.dart';

import '../assembly/relative_path.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';

/// Assembly support Phase 15 (`docs/assembly-scope.md` §6): the "where
/// should this Part's own file live" prompt - fired from "Create
/// Component…" (once, right after creating the new Part) and from "Save
/// All" (once per Part still missing a known path). Reuses `_openMateEdit`'s
/// own `AlertDialog` + `StatefulBuilder` + `TextFormField` +
/// disabled-until-valid `FilledButton` shape (`part_screen.dart`) - the
/// closest existing precedent in this codebase for "a small modal
/// collecting one piece of validated text before enabling a confirm
/// action" - rather than inventing a new one.
///
/// Returns the confirmed, extension-defaulted relative path, or `null` if
/// the user cancelled/skipped.
Future<String?> showRelativePathPromptDialog(
  BuildContext context, {
  required String title,
  required String initialValue,
  required StorageService storageService,
  required ProjectRoot root,
  bool skippable = false,
}) async {
  String value = initialValue;
  String? validationError = validateProjectRelativePath(value);
  bool checkingCollision = false;
  bool collisionWarning = false;

  Future<void> checkCollision(void Function(void Function()) setDialogState) async {
    final path = withDefaultExtension(value);
    setDialogState(() => checkingCollision = true);
    final existing = await storageService.resolve(root, path);
    setDialogState(() {
      checkingCollision = false;
      collisionWarning = existing != null;
    });
  }

  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: Text(title),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            TextFormField(
              initialValue: value,
              autofocus: true,
              decoration: InputDecoration(
                labelText: 'File name',
                helperText: 'Relative to the project folder',
                errorText: validationError,
              ),
              onChanged: (text) {
                setDialogState(() {
                  value = text;
                  validationError = validateProjectRelativePath(value);
                  collisionWarning = false;
                });
                if (validationError == null) {
                  unawaited(checkCollision(setDialogState));
                }
              },
            ),
            if (checkingCollision)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: LinearProgressIndicator(),
              ),
            if (collisionWarning)
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'A file already exists at this path - Save All will overwrite it.',
                  style: TextStyle(color: Colors.orange),
                ),
              ),
          ],
        ),
        actions: [
          if (skippable)
            TextButton(
              onPressed: () => Navigator.of(context).pop(null),
              child: const Text('Skip - save later'),
            )
          else
            TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
          FilledButton(
            onPressed: validationError == null
                ? () => Navigator.of(context).pop(withDefaultExtension(value))
                : null,
            child: const Text('Save'),
          ),
        ],
      ),
    ),
  );
}

/// The simpler sibling prompt for "Open Project…" - the root-relative path
/// of an existing file to open (`AssemblyDocumentClient.openAssembly`
/// itself reports a missing/unreadable file via `StorageException`, so this
/// only needs to validate the path is syntactically safe, not that
/// something already exists there - unlike [showRelativePathPromptDialog]'s
/// own save-target collision check).
///
/// Save/project overhaul Phase 5 (`docs/save-project-overhaul-scope.md`
/// §3.5): now backed by [StorageService.listFiles] - every `.DIDSAprt` file
/// already under [root] is shown as a tappable row (confirmed on tap, no
/// extra "Open" press needed), replacing what used to be a bare "type the
/// exact relative path" text field with nothing to check it against. The
/// text field is kept below the list as a fallback - for a path
/// [StorageService.listFiles] didn't surface, or simply because typing is
/// faster once the path is known by heart. A `listFiles` failure (an
/// unreachable root) falls back to the text field alone, with a short
/// explanatory note, rather than failing the whole dialog - fetched once,
/// before the dialog opens, rather than adding a loading state inside it.
Future<String?> showOpenProjectPathPromptDialog(
  BuildContext context, {
  required StorageService storageService,
  required ProjectRoot root,
}) async {
  List<String>? files;
  try {
    // `List.of` rather than sorting the returned list in place - nothing in
    // `StorageService.listFiles`'s own contract guarantees the caller gets
    // back a mutable list (a `const []` fallback, e.g., wouldn't survive an
    // in-place `sort()`).
    files = List<String>.of(await storageService.listFiles(root, extensionFilter: kNativeFileExtension))..sort();
  } on StorageException {
    files = null;
  }
  if (!context.mounted) return null;
  final resolvedFiles = files;

  String value = '';
  String? validationError = validateProjectRelativePath(value);
  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) => AlertDialog(
        title: const Text('Open Project'),
        content: SizedBox(
          width: double.maxFinite,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (resolvedFiles == null)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text(
                    "Couldn't list files in this folder - type the file name directly.",
                    style: TextStyle(color: Colors.orange),
                  ),
                )
              else if (resolvedFiles.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(bottom: 8),
                  child: Text('No .DIDSAprt files found in this folder.'),
                )
              else ...[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 240),
                  child: ListView.builder(
                    shrinkWrap: true,
                    itemCount: resolvedFiles.length,
                    itemBuilder: (context, index) {
                      final path = resolvedFiles[index];
                      return ListTile(
                        dense: true,
                        leading: const Icon(Icons.description_outlined),
                        title: Text(path),
                        onTap: () => Navigator.of(context).pop(path),
                      );
                    },
                  ),
                ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Or type a path directly:', style: TextStyle(fontSize: 12)),
                ),
              ],
              TextFormField(
                autofocus: resolvedFiles == null || resolvedFiles.isEmpty,
                decoration: InputDecoration(
                  labelText: 'File name',
                  helperText: 'Relative to the project folder',
                  errorText: validationError,
                ),
                onChanged: (text) => setDialogState(() {
                  value = text;
                  validationError = validateProjectRelativePath(value);
                }),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(null), child: const Text('Cancel')),
          FilledButton(
            onPressed: validationError == null
                ? () => Navigator.of(context).pop(withDefaultExtension(value))
                : null,
            child: const Text('Open'),
          ),
        ],
      ),
    ),
  );
}
