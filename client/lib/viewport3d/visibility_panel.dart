import 'package:flutter/material.dart';

/// How much of a category is shown: every one of its Features, none, or a mix (one sketch hidden from the tree, say).
enum VisibilityChipState { shown, hidden, partial }

/// One category toggle of the [VisibilityPanel].
class VisibilityChipData {
  const VisibilityChipData({
    required this.id,
    required this.label,
    required this.icon,
    required this.state,
    required this.tooltip,
    required this.onTap,
    this.locked = false,
  });

  /// Names the chip in its key (`vis-chip-<id>`).
  final String id;
  final String label;
  final Widget icon;
  final VisibilityChipState state;
  final String tooltip;

  /// Null when there is nothing in the category to hide.
  final VoidCallback? onTap;

  /// The category is being shown whatever its state, because the tool in use needs the user to tap one of it.
  final bool locked;
}

/// One standard-view button of the [VisibilityPanel]'s second row.
class VisibilityViewData {
  const VisibilityViewData({required this.id, required this.label, required this.onTap});

  final String id;
  final String label;
  final VoidCallback? onTap;
}

/// The phone layout's Visibility panel (`docs/touch-viewport-ux-plan.md` section 6): a card with a row of category
/// toggles (`Show`) and a row of standard views (`View`). It stays open until its own close button is tapped. Pure
/// presentation: the parent works out each chip's state and what a tap does.
class VisibilityPanel extends StatelessWidget {
  const VisibilityPanel({
    super.key,
    required this.chips,
    required this.views,
    required this.onClose,
    required this.viewsFolded,
    required this.onViewsFoldedChanged,
  });

  final List<VisibilityChipData> chips;
  final List<VisibilityViewData> views;
  final VoidCallback onClose;

  /// The View row is folded away (the chevron at its left), remembered by the parent for the session.
  final bool viewsFolded;
  final ValueChanged<bool> onViewsFoldedChanged;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Material(
      key: const ValueKey('visibility-panel'),
      elevation: 6,
      color: theme.colorScheme.surfaceContainerHigh,
      borderRadius: BorderRadius.circular(12),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                _RowLabel(
                  text: 'Show',
                  leading: const SizedBox(width: 24),
                ),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(children: [for (final chip in chips) _Chip(chip: chip)]),
                  ),
                ),
                IconButton(
                  key: const ValueKey('vis-close'),
                  tooltip: 'Close',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.close),
                  onPressed: onClose,
                ),
              ],
            ),
            Row(
              children: [
                _RowLabel(
                  text: 'View',
                  leading: SizedBox(
                    width: 24,
                    child: InkResponse(
                      key: const ValueKey('vis-fold-views'),
                      onTap: () => onViewsFoldedChanged(!viewsFolded),
                      child: Icon(viewsFolded ? Icons.chevron_right : Icons.expand_more, size: 20),
                    ),
                  ),
                ),
                if (!viewsFolded)
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: [
                          for (final view in views)
                            Padding(
                              padding: const EdgeInsets.only(right: 4),
                              child: OutlinedButton(
                                key: ValueKey('vis-view-${view.id}'),
                                style: OutlinedButton.styleFrom(
                                  visualDensity: VisualDensity.compact,
                                  padding: const EdgeInsets.symmetric(horizontal: 10),
                                  minimumSize: const Size(0, 32),
                                ),
                                onPressed: view.onTap,
                                child: Text(view.label, style: theme.textTheme.labelSmall),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _RowLabel extends StatelessWidget {
  const _RowLabel({required this.text, required this.leading});

  final String text;
  final Widget leading;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 68,
      child: Row(
        children: [
          leading,
          Flexible(child: Text(text, style: Theme.of(context).textTheme.labelMedium, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
  }
}

/// A 40 dp icon chip with its short label under it: filled when everything in the category is shown, outlined when none is,
/// half-filled for a mix; a lock badge while the tool in use is showing it anyway.
class _Chip extends StatelessWidget {
  const _Chip({required this.chip});

  final VisibilityChipData chip;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final scheme = theme.colorScheme;
    final enabled = chip.onTap != null;
    final fill = scheme.primaryContainer;
    final foreground = enabled ? scheme.onSurface : scheme.onSurface.withValues(alpha: 0.38);
    final BoxDecoration decoration = switch (chip.state) {
      VisibilityChipState.shown => BoxDecoration(
          color: fill,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.primary),
        ),
      VisibilityChipState.hidden => BoxDecoration(
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.outline),
        ),
      VisibilityChipState.partial => BoxDecoration(
          gradient: LinearGradient(
            colors: [fill, fill, Colors.transparent, Colors.transparent],
            stops: const [0, 0.5, 0.5, 1],
          ),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: scheme.primary),
        ),
    };
    return Tooltip(
      message: chip.tooltip,
      child: InkWell(
        key: ValueKey('vis-chip-${chip.id}'),
        borderRadius: BorderRadius.circular(10),
        onTap: chip.onTap,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  Container(
                    key: ValueKey('vis-chip-box-${chip.id}'),
                    width: 40,
                    height: 40,
                    decoration: decoration,
                    child: IconTheme(
                      data: IconThemeData(color: foreground, size: 22),
                      child: Center(child: chip.icon),
                    ),
                  ),
                  if (chip.locked)
                    Positioned(
                      top: -3,
                      right: -3,
                      child: Container(
                        key: ValueKey('vis-lock-${chip.id}'),
                        padding: const EdgeInsets.all(2),
                        decoration: BoxDecoration(color: scheme.tertiary, shape: BoxShape.circle),
                        child: Icon(Icons.lock, size: 10, color: scheme.onTertiary),
                      ),
                    ),
                ],
              ),
              const SizedBox(height: 2),
              Text(
                chip.label,
                style: theme.textTheme.labelSmall?.copyWith(color: foreground),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
