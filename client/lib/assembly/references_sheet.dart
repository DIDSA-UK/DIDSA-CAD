import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

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
  });

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

  Widget _row(BuildContext context, ReferenceReport report) {
    final scheme = Theme.of(context).colorScheme;
    final (IconData icon, Color color, String why) = switch (report.outcome) {
      ReferenceOutcome.movedById => (
          Icons.check_circle_outline,
          Colors.green,
          'Found by its part id in ${report.foundPath}. The path is corrected; save to keep it.',
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
