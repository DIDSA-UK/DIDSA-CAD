import 'package:flutter/material.dart';

import 'selection_hit_test.dart';

/// Stage 23 Item 5: the persistent (non-modal) drawer listing every
/// currently-selected mesh entity - [PartScreen] decides when/where to show
/// this (gated on [selectedEntities] being non-empty, the same split
/// [SelectionContextPanel] uses); this widget always renders its content.
/// Removing the last entity is handled entirely by that gating - once
/// [onRemove] empties [selectedEntities], [PartScreen] simply stops showing
/// this widget, no separate "close" affordance needed.
class SelectionListDrawer extends StatelessWidget {
  final Set<SelectionEntityRef> selectedEntities;
  final void Function(SelectionEntityRef entity) onRemove;

  const SelectionListDrawer({
    super.key,
    required this.selectedEntities,
    required this.onRemove,
  });

  @override
  Widget build(BuildContext context) {
    if (selectedEntities.isEmpty) return const SizedBox.shrink();
    final entries = selectedEntities.toList()
      ..sort((a, b) {
        final kindOrder = a.kind.index.compareTo(b.kind.index);
        return kindOrder != 0 ? kindOrder : a.id.compareTo(b.id);
      });
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 160),
      child: Material(
        elevation: 2,
        borderRadius: const BorderRadius.vertical(top: Radius.circular(12)),
        child: ListView.builder(
          shrinkWrap: true,
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
      ),
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
