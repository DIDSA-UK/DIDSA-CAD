import 'package:material_ui/material_ui.dart';

import 'reference_report.dart';

/// What the user answered to [showFolderMatchDialog].
class FolderMatchAnswer {
  const FolderMatchAnswer({required this.useThem, required this.dontAskAgain});

  final bool useThem;
  final bool dontAskAgain;
}

/// "6 files look like they moved with the project folder": the question asked **before** importing when an Open found references
/// with no stored id whose files sit at the same path under another folder ([ReferenceOutcome.likely]). Null when dismissed
/// (treated as Not now by the caller, without storing anything).
Future<FolderMatchAnswer?> showFolderMatchDialog(BuildContext context, List<ReferenceReport> likely) {
  var dontAsk = false;
  final examples = likely.take(3).toList();
  return showDialog<FolderMatchAnswer>(
    context: context,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) => AlertDialog(
        key: const Key('folder-match-dialog'),
        title: Text('${likely.length} ${likely.length == 1 ? 'file looks' : 'files look'} like '
            '${likely.length == 1 ? 'it' : 'they'} moved with the project folder'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('These references have no recorded part id, but a file with the same folder and name is in the project folder.'),
            const SizedBox(height: 8),
            for (final report in examples)
              Padding(
                padding: const EdgeInsets.only(bottom: 4),
                child: Text('${report.requestedPath}  →  ${report.foundPath}', style: const TextStyle(fontSize: 12)),
              ),
            if (likely.length > examples.length) Text('…and ${likely.length - examples.length} more', style: const TextStyle(fontSize: 12)),
            const SizedBox(height: 8),
            CheckboxListTile(
              key: const Key('folder-match-dont-ask'),
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text("Don't ask again this session"),
              value: dontAsk,
              onChanged: (value) => setState(() => dontAsk = value ?? false),
            ),
          ],
        ),
        actions: [
          TextButton(
            key: const Key('folder-match-not-now'),
            onPressed: () => Navigator.of(context).pop(FolderMatchAnswer(useThem: false, dontAskAgain: dontAsk)),
            child: const Text('Not now'),
          ),
          FilledButton(
            key: const Key('folder-match-use'),
            onPressed: () => Navigator.of(context).pop(FolderMatchAnswer(useThem: true, dontAskAgain: dontAsk)),
            child: const Text('Use them'),
          ),
        ],
      ),
    ),
  );
}
