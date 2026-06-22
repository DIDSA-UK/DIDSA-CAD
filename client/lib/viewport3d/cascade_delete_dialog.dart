import 'package:flutter/material.dart';

/// Confirms a cascade delete by naming every Feature it will remove, by
/// display name - not a generic "this and everything after it" message -
/// so the user can see exactly what they're about to lose before
/// confirming. Returns `true` only if the user taps the destructive
/// confirm button; cancelling (the Cancel button, tapping outside, or the
/// back gesture) all resolve to `false`/`null`, and the caller treats
/// anything other than `true` as "do nothing".
Future<bool> showCascadeDeleteDialog(BuildContext context, List<String> featureNamesToDelete) async {
  final count = featureNamesToDelete.length;
  final confirmed = await showDialog<bool>(
    context: context,
    builder: (context) => AlertDialog(
      title: Text(count == 1 ? 'Delete this feature?' : 'Delete $count features?'),
      content: Text(
        'This will permanently delete the following feature${count == 1 ? '' : 's'}:\n\n'
        '${featureNamesToDelete.join('\n')}',
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(false),
          child: const Text('Cancel'),
        ),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: Colors.red.shade700),
          onPressed: () => Navigator.of(context).pop(true),
          child: Text(count == 1 ? 'Delete' : 'Delete all'),
        ),
      ],
    ),
  );
  return confirmed ?? false;
}
