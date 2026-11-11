import 'package:flutter/foundation.dart';
import 'package:material_ui/material_ui.dart';

import 'folder_match_session_choice.dart';
import 'reference_report.dart';

/// Finding moved files (`docs/moved-files-scope.md` section 4): the Review sheet behind the "files were found in new places"
/// banner and the assembly tree's missing-file badge. One row per reference [AssemblyGraphComposer] reported - found by id in
/// a new place (nothing to do), several copies to pick from, a suggestion, or missing - each with Use, Locate... and Leave
/// missing. A file that is not known to be the placed part (a suggestion, or a file picked by hand) is only used after the
/// user confirms; the sheet never swaps a file in on its own.
class ReferencesSheet extends StatefulWidget {
  const ReferencesSheet({
    super.key,
    required this.reports,
    required this.onUse,
    required this.onLocate,
    required this.onLeaveMissing,
    this.notice,
    this.folderChangeOffer,
    this.onApplyFolderChange,
    this.onUseAllSingle,
    this.sessionChoice,
  });

  /// A short line shown under the summary ("Found 3 more references inside Sub.didsa"): why the list grew (item 1a).
  final ValueListenable<String?>? notice;

  /// How many other open references the folder change just made (by a Use or Locate...) would also fix, and the action that
  /// applies it to them all in one merge (item 1c). Null count / zero hides the button.
  final ValueListenable<int>? folderChangeOffer;
  final Future<void> Function()? onApplyFolderChange;

  /// "Use all single suggestions" (item 1c): relinks every open reference with exactly one candidate, in one merge.
  final Future<void> Function(List<ReferenceReport> reports)? onUseAllSingle;

  /// The app-wide answer to the folder-match question, shown with Ask again (item 1b).
  final FolderMatchSessionChoice? sessionChoice;

  /// The references still to show; the parent removes one as it is dealt with.
  final ValueListenable<List<ReferenceReport>> reports;

  /// Use [path] for [report]'s Occurrence (the parent re-links it in the open assembly).
  final Future<void> Function(ReferenceReport report, String path) onUse;

  /// Pick a file by hand for [report] (the parent asks for it, and confirms if it is a different part).
  final Future<void> Function(ReferenceReport report) onLocate;

  final void Function(ReferenceReport report) onLeaveMissing;

  @override
  State<ReferencesSheet> createState() => _ReferencesSheetState();

  static Future<bool> confirmDifferentFile(BuildContext context, String path) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Not the placed file'),
        content: Text('$path is not the file that was placed here. Use it anyway?'),
        actions: [
          TextButton(onPressed: () => Navigator.of(context).pop(false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.of(context).pop(true), child: const Text('Use anyway')),
        ],
      ),
    );
    return confirmed == true;
  }
}

class _ReferencesSheetState extends State<ReferencesSheet> {
  /// True while Use or Locate... is being applied: a second tap on any button waits, so a double tap can't re-link twice.
  bool _busy = false;

  Future<void> _run(Future<void> Function() action) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await action();
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: ValueListenableBuilder<List<ReferenceReport>>(
        valueListenable: widget.reports,
        builder: (context, list, _) {
          final ordered = [...list.where((r) => r.needsYou), ...list.where((r) => !r.needsYou)];
          return ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.of(context).size.height * 0.8),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                  child: Text(
                    referenceSummary(list) ?? 'All references are dealt with',
                    style: Theme.of(context).textTheme.titleMedium,
                  ),
                ),
                if (widget.notice != null)
                  ValueListenableBuilder<String?>(
                    valueListenable: widget.notice!,
                    builder: (context, text, _) => text == null
                        ? const SizedBox.shrink()
                        : Padding(
                            key: const Key('references-notice'),
                            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
                            child: Text(text, style: const TextStyle(fontSize: 12, fontStyle: FontStyle.italic)),
                          ),
                  ),
                ..._header(context, list),
                const Divider(),
                Flexible(
                  child: ListView(
                    shrinkWrap: true,
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 16),
                        child: Text(
                          'A corrected path is an unsaved change until you save. A file that is not the placed part is never '
                          'used without asking.',
                          style: TextStyle(fontSize: 12),
                        ),
                      ),
                      for (final report in ordered) _row(context, report),
                    ],
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  /// The sheet's bulk actions and the stored folder-match answer.
  List<Widget> _header(BuildContext context, List<ReferenceReport> list) {
    final single = [
      for (final r in list)
        if ((r.outcome == ReferenceOutcome.suggest || r.outcome == ReferenceOutcome.likely) && r.candidates.length == 1) r,
    ];
    final choice = widget.sessionChoice;
    return [
      if (choice != null)
        ListenableBuilder(
          listenable: choice,
          builder: (context, _) {
            final answer = choice.answer;
            if (answer == null) return const SizedBox.shrink();
            return Padding(
              key: const Key('folder-match-session-line'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 4),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      answer ? 'Folder matches: used automatically this session' : 'Folder matches: left as suggestions this session',
                      style: const TextStyle(fontSize: 12),
                    ),
                  ),
                  TextButton(
                    key: const Key('folder-match-ask-again'),
                    onPressed: choice.clear,
                    child: const Text('Ask again'),
                  ),
                ],
              ),
            );
          },
        ),
      if (widget.folderChangeOffer != null)
        ValueListenableBuilder<int>(
          valueListenable: widget.folderChangeOffer!,
          builder: (context, count, _) => count <= 0 || widget.onApplyFolderChange == null
              ? const SizedBox.shrink()
              : Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Align(
                    alignment: Alignment.centerLeft,
                    child: FilledButton.tonal(
                      key: const Key('apply-folder-change'),
                      onPressed: _busy ? null : () => _run(widget.onApplyFolderChange!),
                      child: Text('Apply the same folder change to $count other ${count == 1 ? 'reference' : 'references'}'),
                    ),
                  ),
                ),
        ),
      if (widget.onUseAllSingle != null && single.length > 1)
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          child: Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const Key('use-all-single'),
              onPressed: _busy ? null : () => _run(() => widget.onUseAllSingle!(single)),
              child: Text('Use all single suggestions (${single.length})'),
            ),
          ),
        ),
    ];
  }

  Widget _row(BuildContext context, ReferenceReport report) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String why) = switch (report.outcome) {
      ReferenceOutcome.movedById => (
          Icons.check_circle_outline,
          Colors.green,
          'Found by its part id in ${report.foundPath}. The path is corrected; save to keep it.',
        ),
      ReferenceOutcome.foundByFolder => (
          Icons.check_circle_outline,
          Colors.green,
          'Found by folder in ${report.foundPath}. The path is corrected; save to keep it.',
        ),
      ReferenceOutcome.likely => (
          Icons.drive_file_move_outline,
          Colors.amber,
          'Probably moved with the project folder. Nothing is loaded until you use it:',
        ),
      ReferenceOutcome.ask => (
          Icons.help_outline,
          Colors.amber,
          '${report.candidates.length} files have this part. Pick the one you want; nothing is loaded until you do.',
        ),
      ReferenceOutcome.suggest => (
          Icons.lightbulb_outline,
          Colors.amber,
          report.pathMismatch
              ? 'The file at ${report.requestedPath} is a different part. These have the same name:'
              : 'Not found where it was. These have the same name:',
        ),
      ReferenceOutcome.missing => (Icons.link_off, scheme.error, 'Not found in the project folder.'),
    };
    return Padding(
      key: Key('reference-${report.occurrenceId}'),
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, color: color, size: 20),
              const SizedBox(width: 8),
              Expanded(
                child: Text(report.fileName, style: const TextStyle(fontWeight: FontWeight.w600)),
              ),
            ],
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text('in ${_baseName(report.parentPath)}', key: Key('level-${report.occurrenceId}'), style: const TextStyle(fontSize: 11)),
          ),
          Padding(
            padding: const EdgeInsets.only(left: 28, top: 2),
            child: Text(why, style: const TextStyle(fontSize: 12)),
          ),
          if (report.staleCopy)
            const Padding(
              padding: EdgeInsets.only(left: 28, top: 2),
              child: Text(
                'The file could not be read; its last saved copy is shown.',
                style: TextStyle(fontSize: 12, fontStyle: FontStyle.italic),
              ),
            ),
          for (final path in report.candidates)
            Padding(
              padding: const EdgeInsets.only(left: 28),
              child: Row(
                children: [
                  Expanded(child: Text(path, style: const TextStyle(fontSize: 12))),
                  TextButton(
                    key: Key('use-${report.occurrenceId}-$path'),
                    // Only a file carrying the stored id is known to be the placed part.
                    onPressed: _busy
                        ? null
                        : () => _run(() async {
                              if (report.outcome == ReferenceOutcome.suggest &&
                                  !await ReferencesSheet.confirmDifferentFile(context, path)) {
                                return;
                              }
                              await widget.onUse(report, path);
                            }),
                    child: const Text('Use'),
                  ),
                ],
              ),
            ),
          if (report.needsYou)
            Padding(
              padding: const EdgeInsets.only(left: 20),
              child: Wrap(
                children: [
                  TextButton(
                    key: Key('locate-${report.occurrenceId}'),
                    onPressed: _busy ? null : () => _run(() => widget.onLocate(report)),
                    child: const Text('Locate…'),
                  ),
                  TextButton(
                    key: Key('leave-${report.occurrenceId}'),
                    onPressed: _busy ? null : () => widget.onLeaveMissing(report),
                    child: const Text('Leave missing'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

String _baseName(String path) {
  final normalised = path.replaceAll(r'\', '/');
  return normalised.substring(normalised.lastIndexOf('/') + 1);
}
