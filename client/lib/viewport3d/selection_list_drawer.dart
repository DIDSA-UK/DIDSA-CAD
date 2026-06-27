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

  /// Clears the bottom-right FAB column (each FAB is 56dp wide with 16dp of
  /// margin from the Scaffold edge) - matches the brief's example value.
  static const double _fabColumnClearance = 72;

  const SelectionListDrawer({
    super.key,
    required this.selectedEntities,
    required this.onRemove,
    this.header,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedEntities.isEmpty) return const SizedBox.shrink();
    final entries = selectedEntities.toList()
      ..sort((a, b) {
        final kindOrder = a.kind.index.compareTo(b.kind.index);
        return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
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
                        title: Text('${_labelFor(entity.kind)} #${entity.id}'),
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
    }
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
