import 'package:material_ui/material_ui.dart';

import '../../assembly/save_all.dart' show ChangedOnDiskChoice;
import 'sync_conflicts.dart';

/// The conflict dialog (`docs/shared-storage-scope.md` section 6): one row per file the store refused, saying who changed it and
/// when, and the three choices. Returns a choice for every file, or null when the user leaves them for later (the saves stay queued
/// as clashes, and the sync chip offers the dialog again).
Future<Map<String, ConflictChoice>?> showSyncConflictDialog(BuildContext context, List<SyncConflict> conflicts) {
  return showDialog<Map<String, ConflictChoice>>(
    context: context,
    barrierDismissible: false,
    builder: (context) => _SyncConflictDialog(conflicts: conflicts),
  );
}

class _SyncConflictDialog extends StatefulWidget {
  const _SyncConflictDialog({required this.conflicts});

  final List<SyncConflict> conflicts;

  @override
  State<_SyncConflictDialog> createState() => _SyncConflictDialogState();
}

class _SyncConflictDialogState extends State<_SyncConflictDialog> {
  final Map<String, ConflictChoice> _choices = {};

  static const _labels = {
    ConflictChoice.keepMine: 'Keep mine',
    ConflictChoice.takeTheirs: 'Take theirs',
    ConflictChoice.saveCopy: 'Save mine as a copy',
  };

  static const _explanations = {
    ConflictChoice.keepMine: 'Writes mine as the next version over theirs. Theirs stays in the server history.',
    ConflictChoice.takeTheirs: 'Drops my change and loads theirs. Mine is kept on this device until the next sync.',
    ConflictChoice.saveCopy: 'Saves mine next to theirs as a new file with its own Part id.',
  };

  @override
  Widget build(BuildContext context) {
    final all = _choices.length == widget.conflicts.length;
    return AlertDialog(
      key: const ValueKey('sync-conflict-dialog'),
      title: Text(widget.conflicts.length == 1 ? 'This file changed on the server' : '${widget.conflicts.length} files changed on the server'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text('Nothing was written. Choose what to do with each file, then the save is sent again.'),
              const SizedBox(height: 12),
              for (final conflict in widget.conflicts) _row(context, conflict),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('conflict-later'), onPressed: () => Navigator.of(context).pop(), child: const Text('Decide later')),
        FilledButton(
          key: const ValueKey('conflict-apply'),
          onPressed: all ? () => Navigator.of(context).pop(Map.of(_choices)) : null,
          child: const Text('Apply'),
        ),
      ],
    );
  }

  Widget _row(BuildContext context, SyncConflict conflict) {
    final chosen = _choices[conflict.path];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(conflict.path, style: const TextStyle(fontWeight: FontWeight.w600)),
          Text(conflict.describe(), key: ValueKey('conflict-describe-${conflict.path}'), style: Theme.of(context).textTheme.bodySmall),
          const SizedBox(height: 4),
          Wrap(
            spacing: 8,
            children: [
              for (final choice in ConflictChoice.values)
                ChoiceChip(
                  key: ValueKey('conflict-${choice.name}-${conflict.path}'),
                  label: Text(_labels[choice]!),
                  selected: chosen == choice,
                  onSelected: choice == ConflictChoice.keepMine && !conflict.clash.canKeepMine
                      ? null
                      : (_) => setState(() => _choices[conflict.path] = choice),
                ),
            ],
          ),
          if (chosen != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(_explanations[chosen]!, style: Theme.of(context).textTheme.bodySmall)),
        ],
      ),
    );
  }
}

/// Save All on a local folder found files that changed on disk since this session read them (decision S0-8): the user chooses
/// instead of the files being overwritten silently.
Future<ChangedOnDiskChoice> showChangedOnDiskDialog(BuildContext context, List<String> paths) async {
  final choice = await showDialog<ChangedOnDiskChoice>(
    context: context,
    barrierDismissible: false,
    builder: (context) => AlertDialog(
      key: const ValueKey('changed-on-disk-dialog'),
      title: Text(paths.length == 1 ? 'A file changed on disk' : '${paths.length} files changed on disk'),
      content: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('These were modified after this session read them (by a sync client, another program or another device). Saving would overwrite those changes.'),
            const SizedBox(height: 8),
            for (final path in paths) Text('• $path'),
          ],
        ),
      ),
      actions: [
        TextButton(key: const ValueKey('changed-cancel'), onPressed: () => Navigator.of(context).pop(ChangedOnDiskChoice.cancel), child: const Text('Cancel')),
        TextButton(key: const ValueKey('changed-skip'), onPressed: () => Navigator.of(context).pop(ChangedOnDiskChoice.skipChanged), child: const Text('Skip these files')),
        FilledButton(key: const ValueKey('changed-overwrite'), onPressed: () => Navigator.of(context).pop(ChangedOnDiskChoice.overwrite), child: const Text('Overwrite')),
      ],
    ),
  );
  return choice ?? ChangedOnDiskChoice.cancel;
}
