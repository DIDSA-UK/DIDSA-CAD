import 'package:material_ui/material_ui.dart';

import '../project_root.dart';
import 'remote_storage_service.dart';

/// The status chip of a server project: Synced / "N to send" / Clash / Offline (`docs/shared-storage-scope.md` section 7). Tapping it
/// opens the sync sheet: send now, settle clashes, discard a save the store will not take.
class ServerSyncChip extends StatelessWidget {
  const ServerSyncChip({super.key, required this.remote, required this.root, this.onSyncNow, this.onResolve});

  final RemoteStorageService remote;
  final ServerProjectRoot root;

  /// Sync now (the screen runs [RemoteStorageService.sync] and reports).
  final Future<void> Function()? onSyncNow;

  /// Opens the conflict dialog.
  final Future<void> Function()? onResolve;

  static ({String label, IconData icon, Color? color}) describe(SyncSummary s, ColorScheme scheme) {
    if (s.clash > 0) {
      return (label: s.clash == 1 ? 'Clash' : '${s.clash} clashes', icon: Icons.warning_amber_rounded, color: scheme.error);
    }
    if (s.toSend > 0) {
      return (label: '${s.toSend} to send${s.online == false ? ' · offline' : ''}', icon: Icons.cloud_upload_outlined, color: scheme.tertiary);
    }
    if (s.online == false) return (label: 'Offline', icon: Icons.cloud_off_outlined, color: scheme.outline);
    return (label: 'Synced', icon: Icons.cloud_done_outlined, color: scheme.primary);
  }

  @override
  Widget build(BuildContext context) {
    final notifier = remote.statusOf(root);
    return ValueListenableBuilder<SyncSummary>(
      valueListenable: notifier,
      builder: (context, summary, _) {
        final look = describe(summary, Theme.of(context).colorScheme);
        return ActionChip(
          key: const ValueKey('server-sync-chip'),
          avatar: Icon(look.icon, size: 18, color: look.color),
          label: Text(look.label),
          tooltip: '${root.project} on the project store',
          onPressed: () => showServerSyncSheet(context, remote, root, onSyncNow: onSyncNow, onResolve: onResolve),
        );
      },
    );
  }
}

Future<void> showServerSyncSheet(
  BuildContext context,
  RemoteStorageService remote,
  ServerProjectRoot root, {
  Future<void> Function()? onSyncNow,
  Future<void> Function()? onResolve,
}) {
  return showModalBottomSheet<void>(
    context: context,
    builder: (context) => ValueListenableBuilder<SyncSummary>(
      valueListenable: remote.statusOf(root),
      builder: (context, summary, _) {
        final look = ServerSyncChip.describe(summary, Theme.of(context).colorScheme);
        return SafeArea(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              key: const ValueKey('server-sync-sheet'),
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(root.project, style: Theme.of(context).textTheme.titleMedium),
                const SizedBox(height: 4),
                Text(
                  summary.online == false
                      ? 'The project store cannot be reached. Saves are kept on this device and sent when it can.'
                      : 'Connected to the project store.',
                ),
                const SizedBox(height: 8),
                Row(children: [Icon(look.icon, color: look.color), const SizedBox(width: 8), Text(look.label)]),
                if (summary.lastSyncedAt != null) Text('Last synced ${summary.lastSyncedAt!.toLocal()}', style: Theme.of(context).textTheme.bodySmall),
                if (summary.keptCopies > 0)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Text('${summary.keptCopies} of your versions are kept on this device until the next sync.', style: Theme.of(context).textTheme.bodySmall),
                  ),
                for (final problem in summary.problems.entries)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Expanded(child: Text(problem.value, style: TextStyle(color: Theme.of(context).colorScheme.error))),
                        TextButton(
                          key: ValueKey('discard-${problem.key}'),
                          onPressed: () => remote.discardQueued(root, problem.key),
                          child: const Text('Discard'),
                        ),
                      ],
                    ),
                  ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 8,
                  children: [
                    if (summary.clash > 0 && onResolve != null)
                      FilledButton(
                        key: const ValueKey('sync-sheet-resolve'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          onResolve();
                        },
                        child: const Text('Resolve…'),
                      ),
                    if (onSyncNow != null)
                      OutlinedButton(
                        key: const ValueKey('sync-sheet-sync'),
                        onPressed: () {
                          Navigator.of(context).pop();
                          onSyncNow();
                        },
                        child: const Text('Sync now'),
                      ),
                  ],
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}
