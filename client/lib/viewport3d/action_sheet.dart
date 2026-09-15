import 'package:flutter/material.dart';

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
    required this.icon,
    this.enabled = true,
    this.disabledReason,
  });

  /// The value [showActionSheet] resolves to when this row is tapped.
  final T action;
  final String label;
  final IconData icon;

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
  return showModalBottomSheet<T>(
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
                leading: Icon(entry.icon),
                title: Text(entry.label),
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
