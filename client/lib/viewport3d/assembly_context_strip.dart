import 'dart:math' as math;

import 'package:material_ui/material_ui.dart';

/// The strip above the assembly tree while a level is focused (B3, `docs/assembly-tree-overhaul-scope.md` section 4): every level of the focus
/// path as a crumb, the root first. A crumb above the last one jumps there (the host pops the focus to that depth); the last is where the focus
/// is. The root crumb stands for the root row, which the tree does not draw while the strip is on (rule 5: nothing twice).
///
/// Scrolls sideways when the path is longer than the pane, kept at its end so the focused level is always in view.
class FocusBreadcrumbStrip extends StatelessWidget {
  const FocusBreadcrumbStrip({super.key = const ValueKey('focus-strip'), required this.labels, required this.onCrumb});

  /// The root's label, then one label per focused level.
  final List<String> labels;

  /// A crumb was tapped: its depth (0 is the root, `labels.length - 1` the focused level, which does nothing).
  final ValueChanged<int> onCrumb;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final last = labels.length - 1;
    return Material(
      color: scheme.tertiaryContainer.withValues(alpha: 0.4),
      child: SizedBox(
        height: 36,
        // Scrolled to its end (the focused level stays in view), but a path that fits starts at the left: the content is at least as wide as
        // the strip, so a reversed scroll view has nothing to push it right.
        child: LayoutBuilder(
          builder: (context, constraints) => SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            reverse: true,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: math.max(0, constraints.maxWidth - 16)),
              child: Row(
                children: [
                  for (var i = 0; i < labels.length; i++) ...[
                    if (i > 0) Icon(Icons.chevron_right, size: 16, color: scheme.onSurfaceVariant),
                    InkWell(
                      key: ValueKey('focus-crumb:$i'),
                      borderRadius: BorderRadius.circular(4),
                      onTap: i == last ? null : () => onCrumb(i),
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        child: Text(
                          labels[i],
                          maxLines: 1,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: i == last ? FontWeight.bold : FontWeight.normal,
                            color: i == last ? scheme.onSurface : scheme.primary,
                          ),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// What the Edit Alone strip says (B3): the target, the levels above it and how often its Part is placed.
class AssemblyEditAloneInfo {
  const AssemblyEditAloneInfo({required this.label, this.inLabels = const [], this.usedCount});
  final String label;

  /// The levels above the target, the root first.
  final List<String> inLabels;

  /// How many times the target's Part is placed in the document; null while that is not known.
  final int? usedCount;
}

/// "Editing <label>  [Done]" of Edit Alone, with (in the tree) the read-only line "in Rover > Mast" (each crumb leaves Edit Alone at that level)
/// and "used N x" when the target's Part is placed more than once: an edit changes every placement (section 4). One strip replaces the old
/// Edit Alone row and the root row.
///
/// With a tree open it is the strip above the tree ([AssemblyTreeView]), so it never covers the tree; with no tree open `PartScreen` shows it as
/// a pill at the top of the viewport instead ([pill]). Both carry the keys `edit-alone-pill` and `edit-alone-done`.
class EditAloneStrip extends StatelessWidget {
  const EditAloneStrip({
    super.key = const ValueKey('edit-alone-pill'),
    required this.label,
    required this.onDone,
    this.pill = false,
    this.inLabels = const [],
    this.onCrumb,
    this.usedCount,
  });

  final String label;
  final VoidCallback onDone;

  /// True for the floating pill (rounded, raised, one line); false for the strip above a tree.
  final bool pill;

  /// The levels above the target, the root first (`Rover`, `Mast`); empty when nothing is above it.
  final List<String> inLabels;

  /// A crumb of [inLabels] was tapped: its index. Null leaves the crumbs plain text.
  final ValueChanged<int>? onCrumb;

  /// How many times the target's Part is placed in the document; shown only from 2.
  final int? usedCount;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final used = usedCount != null && usedCount! > 1 ? 'used $usedCount \u00D7' : null;
    final muted = TextStyle(fontSize: 12, color: scheme.onSecondaryContainer.withValues(alpha: 0.8));
    final first = Padding(
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
          // An edit changes every placement: the count is part of the first line, so the line below keeps its whole width for the levels.
          if (used != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(used, key: const ValueKey('edit-alone-used'), maxLines: 1, style: muted.copyWith(fontWeight: FontWeight.w600)),
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
      return Material(elevation: 3, color: scheme.secondaryContainer, borderRadius: BorderRadius.circular(24), child: first);
    }
    final second = inLabels.isEmpty
        ? null
        : Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 12, 6),
            child: Row(
              children: [
                Text('in ', key: const ValueKey('edit-alone-in'), style: muted),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (var i = 0; i < inLabels.length; i++) ...[
                          if (i > 0) Text(' > ', style: muted),
                          InkWell(
                            key: ValueKey('edit-alone-crumb:$i'),
                            onTap: onCrumb == null ? null : () => onCrumb!(i),
                            child: Text(
                              inLabels[i],
                              maxLines: 1,
                              style: muted.copyWith(
                                color: onCrumb == null ? muted.color : scheme.primary,
                                decoration: onCrumb == null ? null : TextDecoration.underline,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                ),
              ],
            ),
          );
    return Material(
      color: scheme.secondaryContainer,
      child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [first, if (second != null) second]),
    );
  }
}
