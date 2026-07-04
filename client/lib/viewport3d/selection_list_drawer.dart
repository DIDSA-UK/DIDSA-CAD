import 'package:flutter/material.dart';

import 'selection_hit_test.dart';

/// Stage 23 Item 5 (Fix 5): the persistent (non-modal) drawer listing every
/// currently-selected mesh entity - [PartScreen] decides when/where to show
/// this (gated on [selectedEntities] being non-empty); this widget always
/// renders its content. Removing the last entity is handled entirely by
/// that gating - once [onRemove] empties [selectedEntities], [PartScreen]
/// simply stops showing this widget, no separate "close" affordance needed.
///
/// Fix 5: a [DraggableScrollableSheet] (the project's stated drawer
/// convention) replaces the original fixed-height [ConstrainedBox] - it
/// starts small (`initialChildSize: 0.18`) rather than dominating the
/// screen, and the user can drag it open up to `maxChildSize: 0.4` to see
/// more of a long selection. [header] (the context action panel, see
/// [PartScreen]) renders above the entity list inside the same sheet, so the
/// two stay stacked together with no separate height bookkeeping. A right
/// padding clears the bottom-right FAB column (mode-toggle + Add FABs, see
/// [PartScreen]'s `Scaffold.floatingActionButton`) so the sheet's own
/// content - and its drag handle - are never partially hidden underneath it.
class SelectionListDrawer extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;
  final void Function(SelectionEntityRef entity) onRemove;
  final Widget? header;

  /// B3 revision: stable "Body 1"/"Body 2"... names shared with the feature
  /// tree's "Bodies" section (see `body_naming.dart`'s `bodyDisplayNames`) -
  /// replaces the previous "first 8 characters of body_id" truncation,
  /// which produced two identically-labelled rows for a split Body's two
  /// halves on-device (they share the same base id, only the `#N` suffix
  /// a truncation that short never reaches differs). Falls back to the old
  /// truncation for a bodyId this map doesn't cover (defensive only - every
  /// real call site now always supplies a complete map).
  final Map<String, String> bodyNames;

  /// Clears the bottom-right FAB column (each FAB is 56dp wide with 16dp of
  /// margin from the Scaffold edge) - matches the brief's example value.
  static const double _fabColumnClearance = 72;

  const SelectionListDrawer({
    super.key,
    required this.selectedEntities,
    required this.onRemove,
    this.header,
    this.bodyNames = const {},
  });

  @override
  Widget build(BuildContext context) {
    if (selectedEntities.isEmpty) return const SizedBox.shrink();
    final entries = selectedEntities.toList()
      ..sort((a, b) {
        final kindOrder = a.kind.index.compareTo(b.kind.index);
        if (kindOrder != 0) return kindOrder;
        // Prompt A3: face/edge/vertex ids are only unique within one Body
        // (see SelectionEntityRef's doc comment), so bodyId is a required
        // tiebreak, not just id alone - otherwise two different Bodies'
        // "Face #3" entries would sort nondeterministically against each
        // other. For a Body-kind entry, id is always 0 (meaningless) and
        // bodyId alone already fully orders them.
        final bodyOrder = a.bodyId.compareTo(b.bodyId);
        return bodyOrder != 0 ? bodyOrder : a.id.compareTo(b.id);
      });
    return DraggableScrollableSheet(
      initialChildSize: 0.18,
      minChildSize: 0.12,
      maxChildSize: 0.4,
      builder: (context, scrollController) {
        return SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.only(right: _fabColumnClearance),
            child: Material(
              elevation: 2,
              borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
              child: CustomScrollView(
                // A single scrolling unit (drag handle + header + list, all
                // as slivers sharing one scrollController) rather than a
                // fixed-height Column topped by an Expanded ListView: with
                // the old split, dragging the sheet down toward
                // minChildSize could shrink it below the drag handle's +
                // header's combined height, and Expanded can't go
                // negative - Flutter clipped it to zero and still raised a
                // "RenderFlex overflowed" warning. A CustomScrollView has
                // no such fixed/flexible split to overflow: it just scrolls
                // the header out of view instead.
                controller: scrollController,
                slivers: [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: _DragHandle(),
                    ),
                  ),
                  if (header != null) SliverToBoxAdapter(child: header),
                  SliverList.builder(
                    itemCount: entries.length,
                    itemBuilder: (context, index) {
                      final entity = entries[index];
                      return ListTile(
                        dense: true,
                        leading: Icon(_iconFor(entity.kind)),
                        title: Text(_titleFor(entity)),
                        trailing: IconButton(
                          tooltip: 'Remove from selection',
                          icon: const Icon(Icons.close, size: 18),
                          onPressed: () => onRemove(entity),
                        ),
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  IconData _iconFor(SelectionEntityKind kind) {
    switch (kind) {
      case SelectionEntityKind.face:
        return Icons.square_outlined;
      case SelectionEntityKind.edge:
        return Icons.show_chart;
      case SelectionEntityKind.vertex:
        return Icons.circle;
      case SelectionEntityKind.body:
        return Icons.view_in_ar_outlined;
    }
  }

  String _labelFor(SelectionEntityKind kind) {
    switch (kind) {
      case SelectionEntityKind.face:
        return 'Face';
      case SelectionEntityKind.edge:
        return 'Edge';
      case SelectionEntityKind.vertex:
        return 'Vertex';
      case SelectionEntityKind.body:
        return 'Body';
    }
  }

  /// Prompt A3: a Body entry has no meaningful [SelectionEntityRef.id] (see
  /// its doc comment). B3 revision: names come from [bodyNames] (shared
  /// with the feature tree's "Bodies" section) rather than a raw id
  /// truncation, so e.g. a split Body's two halves read as "Body 1"/
  /// "Body 2" instead of two identical truncated-id rows.
  String _titleFor(SelectionEntityRef entity) {
    if (entity.kind == SelectionEntityKind.body) {
      final id = entity.bodyId;
      return bodyNames[id] ?? 'Body ${id.length > 8 ? id.substring(0, 8) : id}';
    }
    return '${_labelFor(entity.kind)} #${entity.id}';
  }
}

/// A small grab-handle bar hinting that the sheet above is draggable -
/// purely decorative, no gesture handling of its own (the sheet itself
/// already responds to drag anywhere on its content).
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.outlineVariant,
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
