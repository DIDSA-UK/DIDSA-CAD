import 'package:material_ui/material_ui.dart';

/// The "Editing <label>  [Done]" row of Edit Alone (`docs/assembly-perf-mates-and-ui-plan.md`, C1).
///
/// With a tree open it is the first row under the tree's header ([AssemblyTreePanel], [FeatureTreePanel]), so it never covers
/// the tree; with no tree open `PartScreen` shows it as a pill at the top of the viewport instead ([pill]). Both carry the
/// keys `edit-alone-pill` and `edit-alone-done`.
class EditAloneRow extends StatelessWidget {
  const EditAloneRow({super.key = const ValueKey('edit-alone-pill'), required this.label, required this.onDone, this.pill = false});

  final String label;
  final VoidCallback onDone;

  /// True for the floating pill (rounded, raised); false for the flat row inside a tree.
  final bool pill;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final row = Padding(
      padding: EdgeInsets.only(left: pill ? 14 : 16, right: pill ? 4 : 4),
      child: Row(
        mainAxisSize: pill ? MainAxisSize.min : MainAxisSize.max,
        children: [
          Flexible(
            child: Text.rich(
              TextSpan(children: [
                const TextSpan(text: 'Editing '),
                TextSpan(text: label, style: const TextStyle(fontWeight: FontWeight.bold)),
              ]),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 4),
          if (!pill) const Spacer(),
          TextButton.icon(
            key: const ValueKey('edit-alone-done'),
            onPressed: onDone,
            icon: const Icon(Icons.close_fullscreen, size: 18),
            label: const Text('Done'),
          ),
        ],
      ),
    );
    if (pill) {
      return Material(
        elevation: 3,
        color: theme.colorScheme.secondaryContainer,
        borderRadius: BorderRadius.circular(24),
        child: row,
      );
    }
    return Material(color: theme.colorScheme.secondaryContainer, child: row);
  }
}
