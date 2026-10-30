import 'package:flutter/material.dart';

import '../assembly/assembly_lens.dart';
import '../assembly/assembly_lens_theme.dart';
import 'desktop_chrome.dart';
import 'svg_icon.dart';

/// Shows the phone layout's Start menu (`docs/touch-viewport-ux-plan.md` section 4): a Part / Assembly switch, a tab strip
/// and a grid of command tiles. It renders the very [RibbonTabData] the desktop ribbon does, so no command is written
/// twice.
///
/// Completes with the tapped tile's [RibbonCommand] after the sheet has closed, and the caller runs its `onPressed` (pop
/// first, so a tool opens on a clear screen), or with null when the sheet is dismissed.
///
/// [tabs] is called again after every lens switch, which swaps the tab set in place without closing the sheet;
/// [onLensSwitch] must flip the lens synchronously before it returns. [initialTabId] / [onTabChanged] carry the last-used
/// tab per lens, kept by the caller for the session. Phone layout only: a modal bottom sheet, the shape of the Add menu and
/// feature picker it replaces, so the back gesture and a barrier tap dismiss it as they did.
Future<RibbonCommand?> showStartMenuSheet(
  BuildContext context, {
  required List<RibbonTabData> Function() tabs,
  required AssemblyLens Function() lens,
  required VoidCallback onLensSwitch,
  required String? Function(AssemblyLens lens) initialTabId,
  required void Function(AssemblyLens lens, String tabId) onTabChanged,
}) {
  return showModalBottomSheet<RibbonCommand>(
    context: context,
    isScrollControlled: true,
    useSafeArea: true,
    showDragHandle: true,
    shape: const RoundedRectangleBorder(borderRadius: BorderRadius.vertical(top: Radius.circular(16))),
    builder: (context) => StartMenuSheet(
      tabs: tabs,
      lens: lens,
      onLensSwitch: onLensSwitch,
      initialTabId: initialTabId,
      onTabChanged: onTabChanged,
    ),
  );
}

/// The Start menu's body: see [showStartMenuSheet].
class StartMenuSheet extends StatefulWidget {
  const StartMenuSheet({
    super.key,
    required this.tabs,
    required this.lens,
    required this.onLensSwitch,
    required this.initialTabId,
    required this.onTabChanged,
  });

  final List<RibbonTabData> Function() tabs;
  final AssemblyLens Function() lens;
  final VoidCallback onLensSwitch;
  final String? Function(AssemblyLens lens) initialTabId;
  final void Function(AssemblyLens lens, String tabId) onTabChanged;

  /// A command tile's side, per the plan.
  static const double tileSize = 72;

  @override
  State<StartMenuSheet> createState() => _StartMenuSheetState();
}

class _StartMenuSheetState extends State<StartMenuSheet> {
  /// The tab chosen in this sitting for the lens it was chosen in; falls back to the remembered one, then the first tab.
  final Map<AssemblyLens, String> _chosen = {};

  RibbonTabData _selected(List<RibbonTabData> tabs, AssemblyLens lens) {
    final id = _chosen[lens] ?? widget.initialTabId(lens);
    return tabs.firstWhere((t) => t.id == id, orElse: () => tabs.first);
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final lens = widget.lens();
    final tabs = widget.tabs();
    final selected = _selected(tabs, lens);
    final tint = lens == AssemblyLens.assembly ? assemblyLensButtonColors(theme.colorScheme) : null;
    final height = MediaQuery.sizeOf(context).height;
    return Material(
      key: const ValueKey('start-menu'),
      color: tint?.$1.withValues(alpha: 0.35) ?? Colors.transparent,
      child: ConstrainedBox(
        constraints: BoxConstraints(minHeight: height * 0.6, maxHeight: height * 0.9),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 8, 0),
              child: Row(
                children: [
                  SegmentedButton<AssemblyLens>(
                    key: const ValueKey('start-lens'),
                    showSelectedIcon: false,
                    style: SegmentedButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      textStyle: theme.textTheme.labelMedium,
                    ),
                    segments: const [
                      ButtonSegment(value: AssemblyLens.part, label: Text('Part')),
                      ButtonSegment(value: AssemblyLens.assembly, label: Text('Assembly')),
                    ],
                    selected: {lens},
                    onSelectionChanged: (selection) {
                      if (selection.single == lens) return;
                      widget.onLensSwitch();
                      setState(() {});
                    },
                  ),
                  const Spacer(),
                  IconButton(
                    key: const ValueKey('start-menu-close'),
                    tooltip: 'Close',
                    icon: const Icon(Icons.close),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ],
              ),
            ),
            RibbonTabStrip(
              tabs: tabs,
              selectedId: selected.id,
              onSelect: (id) {
                widget.onTabChanged(lens, id);
                setState(() => _chosen[lens] = id);
              },
            ),
            const Divider(height: 1),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 4, 12, 16),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    for (final group in selected.groups) _StartGroup(group: group),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _StartGroup extends StatelessWidget {
  const _StartGroup({required this.group});

  final RibbonGroup group;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        if (group.title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
            child: Text(group.title!, style: theme.textTheme.titleSmall),
          )
        else
          const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [for (final command in group.commands) _StartTile(command: command)],
        ),
      ],
    );
  }
}

/// One command: an icon over a one-line label. Greyed when it cannot run (its tooltip shows on long press), filled when it
/// is a toggle that is on (Measure, Section, the current render mode).
class _StartTile extends StatelessWidget {
  const _StartTile({required this.command});

  final RibbonCommand command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = command.onPressed != null;
    final colour = enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    return Tooltip(
      message: command.tooltip ?? command.label,
      child: SizedBox(
        width: StartMenuSheet.tileSize,
        height: StartMenuSheet.tileSize,
        child: Material(
          color: command.selected ? theme.colorScheme.primaryContainer : theme.colorScheme.surfaceContainerHigh,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            key: ValueKey('start-tile-${command.label}'),
            borderRadius: BorderRadius.circular(10),
            // Disabled tiles stay in the tree so a long press can show why; they just do nothing.
            onTap: enabled ? () => Navigator.of(context).pop(command) : () {},
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 6),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  IconTheme(
                    data: IconThemeData(color: colour, size: 26),
                    child: command.svg != null
                        ? SvgIcon(command.svg!, size: 26, color: colour)
                        : Icon(command.icon ?? Icons.circle_outlined, size: 26, color: colour),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    command.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                    style: theme.textTheme.labelSmall?.copyWith(color: colour),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
