import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import '../layout/adaptive_sheet.dart';

/// Assembly support Phase 3b (`docs/assembly-scope.md` §3): the one
/// bottom-sheet-action-list shell shared by the Assembly-lens "Add" FAB
/// menu (`add_button_menu.dart`'s `showAssemblyAddMenu`) and the new
/// `component_context_menu.dart`'s `showComponentContextMenu` - both are
/// the same shape (a flat list of tappable rows, some of them not backed by
/// a real implementation yet), so this exists once rather than being
/// re-built ad hoc in each file the way the pre-existing Part-lens sheets
/// (`showAddButtonMenu`, `showFeaturePickerSheet`) already independently
/// do. Not a replacement for those two - they predate this shell and have
/// their own bespoke section/column layouts; this is only for the simpler
/// flat-list sheets Phase 3b/4 need.
class ActionSheetEntry<T> {
  const ActionSheetEntry({
    required this.action,
    required this.label,
    this.icon,
    this.leading,
    this.iconColor,
    this.labelColor,
    this.shortcut,
    this.dividerBefore = false,
    this.enabled = true,
    this.disabledReason,
  }) : assert(icon != null || leading != null, 'an entry needs an icon or a leading widget');

  /// The value [showActionSheet] resolves to when this row is tapped.
  final T action;
  final String label;
  final IconData? icon;

  /// Shown instead of [icon] when set (the feature menu's SVG icons).
  final Widget? leading;

  /// Desktop input D4: colours for a destructive row (Delete). Null keeps
  /// the theme's.
  final Color? iconColor;
  final Color? labelColor;

  /// Desktop input D4: the key hint a desktop popup shows at the row's
  /// right edge ("Ctrl+1"). The touch sheet leaves it out.
  final String? shortcut;

  /// Desktop input D4: a desktop popup draws a divider above this row to
  /// group it; the touch sheet ignores it.
  final bool dividerBefore;

  /// Actions with no backing implementation yet (Mate before Phase 6's
  /// solver, Pattern before Phase 7, etc.) pass `enabled: false` rather than
  /// being omitted from the list entirely - `docs/assembly-scope.md`'s own
  /// Phase 3b rationale: the menu's shape stays stable across phases
  /// instead of being re-litigated (and re-tested) each time one of them
  /// actually lands.
  final bool enabled;

  /// Shown as this row's subtitle when [enabled] is false - e.g. `"Coming
  /// soon"`. Ignored when [enabled] is true.
  final String? disabledReason;
}

/// Shows a flat, non-scrolling bottom sheet listing [entries] - pops
/// whichever entry's own [ActionSheetEntry.action] was tapped, or `null` if
/// dismissed without a selection. A disabled entry renders greyed out (via
/// [ListTile.enabled], which restyles the whole row, not just its `onTap`)
/// with [ActionSheetEntry.disabledReason] as its subtitle, and never pops
/// anything when tapped.
Future<T?> showActionSheet<T>(BuildContext context, List<ActionSheetEntry<T>> entries) {
  return showAdaptiveSheet<T>(
    context: context,
    // `isScrollControlled` + a `SingleChildScrollView` (rather than the
    // fixed-height, non-scrolling `Column` this started with): a real
    // caller's entry list (Phase 4's Component context menu has six rows,
    // several with a two-line disabled subtitle) can be taller than a
    // constrained viewport - a short phone in landscape, or this test
    // harness's own fixed surface - overflows, confirmed by a real
    // `RenderFlex overflowed` failure the first version of this widget test
    // caught.
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final entry in entries)
              ListTile(
                enabled: entry.enabled,
                leading: _entryLeading(entry),
                title: Text(entry.label, style: entry.labelColor == null ? null : TextStyle(color: entry.labelColor)),
                subtitle: entry.enabled || entry.disabledReason == null
                    ? null
                    : Text(entry.disabledReason!),
                onTap: entry.enabled ? () => Navigator.of(context).pop(entry.action) : null,
              ),
          ],
        ),
      ),
    ),
  );
}

Widget _entryLeading(ActionSheetEntry<dynamic> entry) =>
    entry.leading ?? Icon(entry.icon, color: entry.iconColor);

/// Desktop input D4 (`docs/desktop-input-scope.md` section 4): one door for
/// every context menu. With [at] (the global position of a mouse right
/// click) it shows a desktop popup there - icon, label, the shortcut as a
/// hint, and a disabled row's reason as its tooltip; without [at] it shows
/// the bottom sheet ([showActionSheet]) exactly as before, so touch is
/// unchanged. Resolves to the tapped entry's action, or null if dismissed.
Future<T?> showContextMenu<T>(BuildContext context, List<ActionSheetEntry<T>> entries, {Offset? at}) {
  if (at == null) return showActionSheet<T>(context, entries);
  final overlay = Navigator.of(context).overlay!.context.findRenderObject()! as RenderBox;
  final theme = Theme.of(context);
  return showMenu<T>(
    context: context,
    position: RelativeRect.fromRect(Rect.fromLTWH(at.dx, at.dy, 0, 0), Offset.zero & overlay.size),
    items: [
      for (final entry in entries) ...[
        if (entry.dividerBefore) const PopupMenuDivider(),
        PopupMenuItem<T>(
          value: entry.action,
          enabled: entry.enabled,
          height: 36,
          child: _popupRow(entry, theme),
        ),
      ],
    ],
  );
}

Widget _popupRow(ActionSheetEntry<dynamic> entry, ThemeData theme) {
  final row = Row(
    mainAxisSize: MainAxisSize.min,
    children: [
      IconTheme.merge(
        data: const IconThemeData(size: 20),
        child: SizedBox(width: 24, child: _entryLeading(entry)),
      ),
      const SizedBox(width: 12),
      Flexible(
        child: Text(entry.label, style: entry.labelColor == null ? null : TextStyle(color: entry.labelColor)),
      ),
      if (entry.shortcut != null) ...[
        const SizedBox(width: 24),
        Text(
          entry.shortcut!,
          style: theme.textTheme.bodySmall?.copyWith(color: theme.colorScheme.onSurfaceVariant),
        ),
      ],
    ],
  );
  final reason = entry.enabled ? null : entry.disabledReason;
  return reason == null ? row : Tooltip(message: reason, child: row);
}

/// Desktop input D4: wraps a row, canvas or panel so a mouse right click
/// (a secondary tap, which a touch long-press never is) calls [onOpen] with
/// the click's global position - the place [showContextMenu] puts its
/// popup. A null [onOpen] leaves [child] untouched.
class MouseContextMenuRegion extends StatelessWidget {
  const MouseContextMenuRegion({super.key, required this.onOpen, required this.child});

  final ValueChanged<Offset>? onOpen;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final open = onOpen;
    if (open == null) return child;
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onSecondaryTapUp: (details) {
        if (details.kind == PointerDeviceKind.mouse) open(details.globalPosition);
      },
      child: child,
    );
  }
}
