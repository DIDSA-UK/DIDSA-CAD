import 'dart:async';

import 'package:flutter/material.dart';

import '../assembly/relative_path.dart';
import '../storage/project_root.dart';
import '../storage/storage_service.dart';

class _BrowseItem {
  final String name;
  final String relativePath;
  final bool isFolder;

  _BrowseItem({
    required this.name,
    required this.relativePath,
    required this.isFolder,
  });
}

List<_BrowseItem> _getBrowseItems(List<String> allFiles, String currentFolder) {
  final items = <String, bool>{};
  final currentPrefix = currentFolder.isEmpty ? '' : '$currentFolder/';

  for (final file in allFiles) {
    if (!file.startsWith(currentPrefix)) continue;

    final relativePart = file.substring(currentPrefix.length);
    if (relativePart.isEmpty) continue;

    // Check if this is a direct child or nested
    final firstSlash = relativePart.indexOf('/');
    if (firstSlash == -1) {
      // Direct file
      items[file] = false;
    } else {
      // Folder - extract folder name
      final folderName = relativePart.substring(0, firstSlash);
      final folderPath = currentPrefix.isEmpty
          ? folderName
          : '$currentPrefix$folderName';
      items[folderPath] = true;
    }
  }

  return items.entries
      .map((e) => _BrowseItem(
        name: e.key.split('/').last,
        relativePath: e.key,
        isFolder: e.value,
      ))
      .toList()
      ..sort((a, b) {
        if (a.isFolder != b.isFolder) {
          return a.isFolder ? -1 : 1; // Folders first
        }
        return a.name.compareTo(b.name);
      });
}

/// Runs the platform folder picker, returning `null` if the user cancelled.
/// `pickOrCreateProjectRoot` persists the picked root itself and signals
/// cancel by throwing [StorageException], never by returning null.
Future<ProjectRoot?> _pickNewProjectRoot(StorageService storageService) async {
  try {
    return await storageService.pickOrCreateProjectRoot();
  } on StorageException {
    return null;
  }
}

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
  ValueChanged<ProjectRoot>? onRootChanged,
}) async {
  // [onRootChanged], when given, adds a "Change Folder" button: the picked
  // root is reported to the caller (which must save relative to it) and used
  // for this dialog's own collision check. Omitted by flows that write many
  // files against one fixed root (Save All, AI orchestration), where
  // switching root mid-flow would be unsafe.
  var currentRoot = root;
  String value = initialValue;
  String? validationError = validateProjectRelativePath(value);
  bool checkingCollision = false;
  bool collisionWarning = false;

  Future<void> checkCollision(void Function(void Function()) setDialogState) async {
    final path = withDefaultExtension(value);
    setDialogState(() => checkingCollision = true);
    final existing = await storageService.resolve(currentRoot, path);
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
          if (onRootChanged != null)
            TextButton(
              onPressed: () async {
                final newRoot = await _pickNewProjectRoot(storageService);
                if (newRoot == null) return;
                currentRoot = newRoot;
                onRootChanged(newRoot);
                if (!context.mounted) return;
                setDialogState(() => collisionWarning = false);
                if (validationError == null) {
                  unawaited(checkCollision(setDialogState));
                }
              },
              child: const Text('Change Folder'),
            ),
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
  ValueChanged<ProjectRoot>? onRootChanged,
}) async {
  // Null when the root is unreachable. `List.of` because nothing in
  // `StorageService.listFiles`'s own contract guarantees the caller gets
  // back a mutable list (a `const []` fallback, e.g., wouldn't survive an
  // in-place `sort()`).
  Future<List<String>?> loadFiles(ProjectRoot forRoot) async {
    try {
      return List<String>.of(await storageService.listFiles(forRoot, extensionFilter: kNativeFileExtension))..sort();
    } on StorageException {
      return null;
    }
  }

  List<String>? files = await loadFiles(root);
  if (!context.mounted) return null;

  String value = '';
  String? validationError = validateProjectRelativePath(value);
  String currentFolder = '';

  return showDialog<String>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setDialogState) {
        final resolvedFiles = files;
        final items = resolvedFiles == null ? null : _getBrowseItems(resolvedFiles, currentFolder);

        return AlertDialog(
          title: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Open Project'),
              if (currentFolder.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Row(
                    children: [
                      TextButton.icon(
                        onPressed: () => setDialogState(() => currentFolder = ''),
                        icon: const Icon(Icons.home, size: 16),
                        label: const Text('Root', style: TextStyle(fontSize: 12)),
                      ),
                      if (currentFolder.isNotEmpty)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: TextButton.icon(
                            onPressed: () {
                              final parent = currentFolder.lastIndexOf('/');
                              setDialogState(() => currentFolder = parent > 0 ? currentFolder.substring(0, parent) : '');
                            },
                            icon: const Icon(Icons.arrow_upward, size: 16),
                            label: const Text('Up', style: TextStyle(fontSize: 12)),
                          ),
                        ),
                    ],
                  ),
                ),
            ],
          ),
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
                else if (items!.isEmpty)
                  const Padding(
                    padding: EdgeInsets.only(bottom: 8),
                    child: Text('No .DIDSAprt files found in this folder.'),
                  )
                else
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxHeight: 240),
                    child: ListView.builder(
                      shrinkWrap: true,
                      itemCount: items.length,
                      itemBuilder: (context, index) {
                        final item = items[index];
                        return ListTile(
                          dense: true,
                          leading: Icon(item.isFolder ? Icons.folder_outlined : Icons.description_outlined),
                          title: Text(item.name),
                          onTap: item.isFolder
                              ? () => setDialogState(() => currentFolder = item.relativePath)
                              : () => Navigator.of(context).pop(item.relativePath),
                        );
                      },
                    ),
                  ),
                const Padding(
                  padding: EdgeInsets.symmetric(vertical: 8),
                  child: Text('Or type a path directly:', style: TextStyle(fontSize: 12)),
                ),
                TextFormField(
                  autofocus: resolvedFiles == null || items!.isEmpty,
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
          if (onRootChanged != null)
            TextButton(
              onPressed: () async {
                final newRoot = await _pickNewProjectRoot(storageService);
                if (newRoot == null) return;
                final newFiles = await loadFiles(newRoot);
                onRootChanged(newRoot);
                if (!context.mounted) return;
                setDialogState(() {
                  files = newFiles;
                  currentFolder = '';
                });
              },
              child: const Text('Change Folder'),
            ),
          FilledButton(
            onPressed: validationError == null
                ? () => Navigator.of(context).pop(withDefaultExtension(value))
                : null,
            child: const Text('Open'),
          ),
        ],
      );
      },
    ),
  );
}
