import 'package:flutter/material.dart';

import 'svg_icon.dart';

/// Desktop layout (D6, `docs/desktop-layout-scope.md` section 2): the pieces
/// of the part screen's desktop frame - the ribbon, the status bar and the
/// resizable left pane. They hold no tool logic: each ribbon button just
/// calls the action the phone layout's FAB or sheet already calls.

/// One button on the ribbon.
class RibbonCommand {
  const RibbonCommand({
    required this.label,
    this.svg,
    this.icon,
    required this.onPressed,
    this.tooltip,
    this.shortcut,
    this.selected = false,
  });

  final String label;

  /// An `assets/icons/...` SVG, or a Material [icon] when there is none.
  final String? svg;
  final IconData? icon;

  /// Null greys the button out.
  final VoidCallback? onPressed;

  final String? tooltip;

  /// The key that does the same, shown in the tooltip.
  final String? shortcut;

  /// A toggle that is on (Measure while measuring).
  final bool selected;
}

/// A run of related buttons, set off from the next by a divider.
class RibbonGroup {
  const RibbonGroup(this.commands, {this.title});

  final List<RibbonCommand> commands;
  final String? title;
}

/// A ribbon tab: its name and button groups.
class RibbonTabData {
  const RibbonTabData({required this.id, required this.label, required this.groups});

  final String id;
  final String label;
  final List<RibbonGroup> groups;
}

/// SOLIDWORKS' CommandManager: a row of tabs and, under it, the active tab's
/// big labelled buttons.
class DesktopRibbon extends StatelessWidget {
  const DesktopRibbon({
    super.key,
    required this.tabs,
    required this.selectedId,
    required this.onSelect,
    this.trailing,
  });

  final List<RibbonTabData> tabs;
  final String selectedId;
  final ValueChanged<String> onSelect;

  /// Right-aligned on the tab row (the Part / Assembly switch).
  final Widget? trailing;

  static const double commandWidth = 68;
  static const double bodyHeight = 78;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final selected = tabs.firstWhere((t) => t.id == selectedId, orElse: () => tabs.first);
    return Material(
      key: const ValueKey('desktop-ribbon'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            height: 32,
            child: Row(
              children: [
                const SizedBox(width: 8),
                for (final tab in tabs)
                  _RibbonTabButton(
                    key: ValueKey('ribbon-tab-${tab.id}'),
                    label: tab.label,
                    selected: tab.id == selected.id,
                    onTap: () => onSelect(tab.id),
                  ),
                const Spacer(),
                if (trailing != null) trailing!,
                const SizedBox(width: 8),
              ],
            ),
          ),
          Container(
            height: bodyHeight,
            width: double.infinity,
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHigh,
              border: Border(
                top: BorderSide(color: theme.colorScheme.outlineVariant),
                bottom: BorderSide(color: theme.colorScheme.outlineVariant),
              ),
            ),
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              children: [
                for (var g = 0; g < selected.groups.length; g++) ...[
                  if (g > 0)
                    VerticalDivider(width: 12, thickness: 1, indent: 6, endIndent: 6, color: theme.colorScheme.outlineVariant),
                  for (final command in selected.groups[g].commands) _RibbonButton(command: command),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RibbonTabButton extends StatelessWidget {
  const _RibbonTabButton({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return InkWell(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? theme.colorScheme.surfaceContainerHigh : null,
          border: Border(
            bottom: BorderSide(color: selected ? theme.colorScheme.primary : Colors.transparent, width: 2),
          ),
        ),
        child: Text(
          label,
          style: theme.textTheme.labelLarge?.copyWith(
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            color: selected ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
          ),
        ),
      ),
    );
  }
}

class _RibbonButton extends StatelessWidget {
  const _RibbonButton({required this.command});

  final RibbonCommand command;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final enabled = command.onPressed != null;
    final colour = enabled ? theme.colorScheme.onSurface : theme.colorScheme.onSurface.withValues(alpha: 0.38);
    final tip = [
      command.tooltip ?? command.label,
      if (command.shortcut != null) '(${command.shortcut})',
    ].join(' ');
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 500),
      child: SizedBox(
        width: DesktopRibbon.commandWidth,
        child: InkWell(
          key: ValueKey('ribbon-${command.label}'),
          borderRadius: BorderRadius.circular(6),
          onTap: command.onPressed,
          child: Container(
            decoration: command.selected
                ? BoxDecoration(
                    color: theme.colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(6),
                  )
                : null,
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 4),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 28,
                  width: 28,
                  child: command.svg != null
                      ? SvgIcon(command.svg!, size: 26, color: colour)
                      : Icon(command.icon ?? Icons.crop_square, size: 26, color: colour),
                ),
                const SizedBox(height: 3),
                Text(
                  command.label,
                  maxLines: 2,
                  textAlign: TextAlign.center,
                  overflow: TextOverflow.ellipsis,
                  style: theme.textTheme.labelSmall?.copyWith(color: colour, height: 1.1),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// The strip along the bottom: what is selected, what is going on.
class DesktopStatusBar extends StatelessWidget {
  const DesktopStatusBar({super.key, required this.left, required this.right});

  final List<String> left;
  final List<String> right;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final style = theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant);
    Widget run(List<String> items) => Text(items.where((s) => s.isNotEmpty).join('   |   '), style: style, maxLines: 1, overflow: TextOverflow.ellipsis);
    return Material(
      key: const ValueKey('desktop-status-bar'),
      color: theme.colorScheme.surfaceContainerLow,
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
        child: Row(
          children: [
            Expanded(child: run(left)),
            run(right),
          ],
        ),
      ),
    );
  }
}

/// The left pane: [child] (the feature or assembly tree) at a width the user
/// can drag, with a thin divider that doubles as the drag handle.
class DesktopLeftPane extends StatefulWidget {
  const DesktopLeftPane({super.key, required this.child, this.initialWidth = 300});

  final Widget child;
  final double initialWidth;

  static const double minWidth = 200;
  static const double maxWidth = 520;

  @override
  State<DesktopLeftPane> createState() => _DesktopLeftPaneState();
}

class _DesktopLeftPaneState extends State<DesktopLeftPane> {
  late double _width = widget.initialWidth;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(key: const ValueKey('desktop-left-pane'), width: _width, child: widget.child),
        MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            key: const ValueKey('desktop-pane-divider'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) => setState(
              () => _width = (_width + details.delta.dx).clamp(DesktopLeftPane.minWidth, DesktopLeftPane.maxWidth),
            ),
            child: Container(width: 6, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
      ],
    );
  }
}
