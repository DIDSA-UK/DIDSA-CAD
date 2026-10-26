import 'package:flutter/material.dart';

/// The "Guide curves" block shared by [LoftPanel] and [LoftSurfacePanel]: a loft can have any number of
/// guides (the backend's `guide_curves`, each an ordered chain of sketch lines, arcs, ellipses or
/// splines). Guides shape the surface; they should touch every section. "Add guide" starts a pick in
/// the viewport where each tap adds one segment of the guide being built; "Done" keeps it as a guide.
/// Each finished guide gets its own row with a remove button.
class LoftGuidesSection extends StatelessWidget {
  /// One entry per finished guide: how many curve segments it is made of.
  final List<int> guideSegmentCounts;

  /// Whether a guide is being picked in the viewport right now, and how many segments it has so far.
  final bool picking;
  final int draftSegments;

  final VoidCallback onAddGuide;
  final VoidCallback onFinishGuide;
  final VoidCallback onCancelGuide;
  final void Function(int index) onRemoveGuide;

  const LoftGuidesSection({
    super.key,
    required this.guideSegmentCounts,
    required this.picking,
    required this.draftSegments,
    required this.onAddGuide,
    required this.onFinishGuide,
    required this.onCancelGuide,
    required this.onRemoveGuide,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (guideSegmentCounts.isEmpty && !picking)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              'No guides. A guide is a curve that runs through every section and shapes the surface between them.',
              style: TextStyle(color: Theme.of(context).colorScheme.onSurfaceVariant, fontSize: 12),
            ),
          ),
        for (var i = 0; i < guideSegmentCounts.length; i++)
          ListTile(
            key: ValueKey('loft-guide-$i'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Guide ${i + 1}'),
            subtitle: Text(guideSegmentCounts[i] == 1 ? '1 curve' : '${guideSegmentCounts[i]} curves'),
            trailing: IconButton(
              tooltip: 'Remove guide ${i + 1}',
              icon: const Icon(Icons.close, size: 18),
              onPressed: picking ? null : () => onRemoveGuide(i),
            ),
          ),
        if (picking)
          ListTile(
            key: const ValueKey('loft-guide-draft'),
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text('Guide ${guideSegmentCounts.length + 1}'),
            subtitle: Text(
              draftSegments == 0
                  ? 'Tap the curves of the guide in the viewport, in order…'
                  : (draftSegments == 1 ? '1 curve picked' : '$draftSegments curves picked'),
            ),
            trailing: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextButton(onPressed: onCancelGuide, child: const Text('Cancel')),
                TextButton(
                  onPressed: draftSegments == 0 ? null : onFinishGuide,
                  child: const Text('Done'),
                ),
              ],
            ),
          )
        else
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: onAddGuide,
              icon: const Icon(Icons.add, size: 18),
              label: const Text('Add guide'),
            ),
          ),
      ],
    );
  }
}

/// Non-blocking messages from the backend about the loft that was built (a guide that was bent to meet
/// a section, a network that had to be approximated), shown under the controls.
class LoftWarnings extends StatelessWidget {
  final List<String> warnings;

  const LoftWarnings({super.key, required this.warnings});

  @override
  Widget build(BuildContext context) {
    if (warnings.isEmpty) return const SizedBox.shrink();
    final color = Theme.of(context).colorScheme.tertiary;
    return Padding(
      padding: const EdgeInsets.only(top: 4),
      child: Column(
        key: const ValueKey('loft-warnings'),
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          for (final warning in warnings)
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.warning_amber_rounded, size: 16, color: color),
                const SizedBox(width: 6),
                Expanded(child: Text(warning, style: TextStyle(fontSize: 12, color: color))),
              ],
            ),
        ],
      ),
    );
  }
}
