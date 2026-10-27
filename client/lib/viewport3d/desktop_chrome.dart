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
    this.showTabStrip = true,
  });

  final List<RibbonTabData> tabs;
  final String selectedId;
  final ValueChanged<String> onSelect;

  /// Right-aligned on the tab row (the Part / Assembly switch).
  final Widget? trailing;

  /// False when the tabs are shown elsewhere (the part screen puts them in the app bar, beside File and View,
  /// to save a row) - only the active tab's buttons are drawn.
  final bool showTabStrip;

  static const double commandWidth = 62;
  static const double bodyHeight = 70;

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
          if (showTabStrip)
            SizedBox(
              height: 32,
              child: Row(
                children: [
                  const SizedBox(width: 8),
                  Expanded(child: RibbonTabStrip(tabs: tabs, selectedId: selectedId, onSelect: onSelect)),
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

/// The ribbon's tab buttons in a row, scrollable when the window is narrow.
class RibbonTabStrip extends StatelessWidget {
  const RibbonTabStrip({super.key, required this.tabs, required this.selectedId, required this.onSelect});

  final List<RibbonTabData> tabs;
  final String selectedId;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final selected = tabs.firstWhere((t) => t.id == selectedId, orElse: () => tabs.first);
    return SizedBox(
      height: kToolbarHeight,
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final tab in tabs)
              _RibbonTabButton(
                key: ValueKey('ribbon-tab-${tab.id}'),
                label: tab.label,
                selected: tab.id == selected.id,
                onTap: () => onSelect(tab.id),
              ),
          ],
        ),
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
            padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                SizedBox(
                  height: 26,
                  width: 26,
                  child: command.svg != null
                      ? SvgIcon(command.svg!, size: 24, color: colour)
                      : Icon(command.icon ?? Icons.crop_square, size: 24, color: colour),
                ),
                const SizedBox(height: 2),
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
/// can drag, with a thin divider that doubles as the drag handle. The width
/// lives with the owner so it survives the pane being swapped out for a
/// tool's panel and back.
class DesktopLeftPane extends StatelessWidget {
  const DesktopLeftPane({super.key, required this.child, required this.width, required this.onResize});

  final Widget child;
  final double width;
  
  /// Called with how far the divider moved; the owner adds it to its width (several moves can arrive between frames).
  final ValueChanged<double> onResize;

  static const double defaultWidth = 300;
  static const double minWidth = 200;
  static const double maxWidth = 520;

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Row(
      children: [
        SizedBox(key: const ValueKey('desktop-left-pane'), width: width, child: child),
        MouseRegion(
          cursor: SystemMouseCursors.resizeLeftRight,
          child: GestureDetector(
            key: const ValueKey('desktop-pane-divider'),
            behavior: HitTestBehavior.opaque,
            onHorizontalDragUpdate: (details) => onResize(details.delta.dx),
            child: Container(width: 6, color: theme.colorScheme.outlineVariant.withValues(alpha: 0.5)),
          ),
        ),
      ],
    );
  }
}
