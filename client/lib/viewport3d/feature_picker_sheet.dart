import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Actions available from the "Add" FAB's second-level Feature picker.
/// [extrude], (C3) [plane], (on-device feedback) [fillet], (Prompt E)
/// [chamfer], (Prompt F) [revolve], and [sweep] are all wired to a real
/// flow.
enum FeaturePickerAction {
  extrude,
  revolve,
  sweep,
  loft,
  plane,
  surface,
  fillet,
  chamfer,
  mirror,
  pattern,
  // Boolean family, first entry.
  merge,
}

/// Shows the fly-up bottom sheet listing every feature type the "Add" FAB's
/// Feature entry offers - same drag-handle/rounded-top-corner shape as
/// [showPlaneContextSheet], so both Stage 19b fly-ups feel consistent.
///
/// Grouped into collapsible sections (mirrors [FeatureTreePanel]'s own
/// Bodies/Planes `ExpansionTile` grouping - `_buildGroupedTree` - rather
/// than a flat list, now that this sheet has grown past a handful of rows):
/// Sketch-based (Extrude/Revolve/Sweep/Loft), Reference (Plane/Surface),
/// Modify (Fillet/Chamfer), and Repeat (Mirror/Pattern - not titled
/// "Pattern" itself, since that collided with the "Pattern" entry it
/// contains - see that section's own doc comment). A Combine section
/// (Merge/Subtract/Common/Split) holds one real entry (Merge) plus three
/// still-disabled placeholders left for their own follow-up sessions to
/// populate - see [_CombineSection].
Future<FeaturePickerAction?> showFeaturePickerSheet(BuildContext context) {
  return showModalBottomSheet<FeaturePickerAction>(
    context: context,
    // C3: added a sixth entry (Plane) - scroll-controlled so this sheet can
    // grow past its old fixed-fraction default height instead of clipping/
    // overflowing on a short viewport (a small phone in landscape, or a
    // split-screen window) the way a fixed-size six-row sheet otherwise
    // risks doing.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      return SafeArea(
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: _DragHandle(),
              ),
              _FeatureSection(
                title: 'Sketch-based',
                initiallyExpanded: true,
                entries: [
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_extrude.svg',
                    label: 'Extrude',
                    action: FeaturePickerAction.extrude,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_revolve.svg',
                    label: 'Revolve',
                    action: FeaturePickerAction.revolve,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_sweep.svg',
                    label: 'Sweep',
                    action: FeaturePickerAction.sweep,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_loft.svg',
                    label: 'Loft',
                    action: FeaturePickerAction.loft,
                  ),
                ],
              ),
              _FeatureSection(
                title: 'Reference',
                initiallyExpanded: true,
                entries: [
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_plane.svg',
                    label: 'Plane',
                    action: FeaturePickerAction.plane,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_surface.svg',
                    label: 'Surface',
                    action: FeaturePickerAction.surface,
                  ),
                ],
              ),
              _FeatureSection(
                title: 'Modify',
                initiallyExpanded: true,
                entries: [
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_fillet.svg',
                    label: 'Fillet',
                    action: FeaturePickerAction.fillet,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_chamfer.svg',
                    label: 'Chamfer',
                    action: FeaturePickerAction.chamfer,
                  ),
                ],
              ),
              _FeatureSection(
                // Bug fix (real CI failure - widget tests): naming this
                // section "Pattern" collided with the "Pattern" entry it
                // contains - `find.text('Pattern')`/a plain tap-by-label
                // could no longer tell the section header from the row
                // inside it (both matched, ambiguously). "Repeat" groups
                // Mirror/Pattern under the same "duplicate existing
                // geometry" umbrella without repeating either entry's own
                // label.
                title: 'Repeat',
                initiallyExpanded: true,
                entries: [
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_mirror.svg',
                    label: 'Mirror',
                    action: FeaturePickerAction.mirror,
                  ),
                  _FeatureEntry(
                    icon: 'assets/icons/feature/feature_pattern.svg',
                    label: 'Pattern',
                    action: FeaturePickerAction.pattern,
                  ),
                ],
              ),
              const _CombineSection(),
              const SizedBox(height: 8),
            ],
          ),
        ),
      );
    },
  );
}

/// One collapsible group of Feature entries - mirrors [FeatureTreePanel]'s
/// own Bodies/Planes `ExpansionTile` convention (dense, compact visual
/// density, a section-weight title) rather than inventing a new grouping
/// widget.
class _FeatureSection extends StatelessWidget {
  final String title;
  final bool initiallyExpanded;
  final List<_FeatureEntry> entries;

  const _FeatureSection({
    required this.title,
    required this.initiallyExpanded,
    required this.entries,
  });

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: initiallyExpanded,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(
        title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      children: [for (final entry in entries) entry],
    );
  }
}

/// One tappable row inside a [_FeatureSection] - pops [action] off the
/// sheet's own `Navigator`, same as every entry did before the ExpansionTile
/// regrouping.
class _FeatureEntry extends StatelessWidget {
  final String icon;
  final String label;
  final FeaturePickerAction action;

  const _FeatureEntry({required this.icon, required this.label, required this.action});

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: SvgIcon(icon),
      title: Text(label),
      onTap: () => Navigator.of(context).pop(action),
    );
  }
}

/// The Combine section (Merge/Subtract/Common/Split) - Boolean family, first
/// entry: [FeaturePickerAction.merge] is now a real, enabled entry (mirrors
/// every other [_FeatureEntry] row); Subtract/Common/Split stay disabled
/// placeholders for their own follow-up sessions to wire up, same reasoning
/// this section always had. A bespoke widget (not a plain [_FeatureSection])
/// since it mixes one real [_FeatureEntry] with three still-disabled rows,
/// which [_FeatureSection] itself has no concept of.
class _CombineSection extends StatelessWidget {
  const _CombineSection();

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: false,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: const Text(
        'Combine',
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      children: const [
        _FeatureEntry(
          icon: 'assets/icons/feature/feature_merge.svg',
          label: 'Merge',
          action: FeaturePickerAction.merge,
        ),
        ListTile(enabled: false, title: Text('Subtract'), subtitle: Text('Coming soon')),
        ListTile(enabled: false, title: Text('Common'), subtitle: Text('Coming soon')),
        ListTile(enabled: false, title: Text('Split'), subtitle: Text('Coming soon')),
      ],
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
