import 'package:flutter/material.dart';

import '../api/document_api_client.dart';
import 'assembly_tree_panel.dart';

/// Assembly lens component selection drawer - the assembly equivalent of
/// [SelectionListDrawer] for Part lens mesh entity selection. Shows the
/// currently-selected component with action buttons (Move, Fix/Float, Delete)
/// in a draggable sheet matching Part lens UI conventions.
class AssemblyComponentSelectionDrawer extends StatelessWidget {
  final OccurrenceDto selectedComponent;
  final VoidCallback onMove;
  final VoidCallback onFixFloat;
  final VoidCallback onDelete;

  static const double _fabColumnClearance = 72;

  const AssemblyComponentSelectionDrawer({
    super.key,
    required this.selectedComponent,
    required this.onMove,
    required this.onFixFloat,
    required this.onDelete,
  });

  @override
  Widget build(BuildContext context) {
    final componentName = occurrenceDisplayName([selectedComponent], 0);

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
                controller: scrollController,
                slivers: [
                  const SliverToBoxAdapter(
                    child: Padding(
                      padding: EdgeInsets.symmetric(vertical: 6),
                      child: _DragHandle(),
                    ),
                  ),
                  SliverToBoxAdapter(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Row(
                            children: [
                              const Icon(Icons.view_in_ar_outlined, size: 20),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  componentName,
                                  style: Theme.of(context).textTheme.titleMedium,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              FilledButton.tonal(
                                onPressed: onMove,
                                child: const Text('Move'),
                              ),
                              FilledButton.tonal(
                                onPressed: onFixFloat,
                                child: Text(selectedComponent.fixed ? 'Float' : 'Fix'),
                              ),
                              FilledButton.tonal(
                                onPressed: onDelete,
                                child: const Text('Delete'),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Minimal drag handle matching [SelectionListDrawer]'s own version.
class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 32,
        height: 4,
        decoration: BoxDecoration(
          color: Theme.of(context).colorScheme.outline.withValues(alpha: 0.4),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
