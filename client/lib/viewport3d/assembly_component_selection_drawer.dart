import 'package:material_ui/material_ui.dart';

import '../layout/layout_mode.dart';

import '../api/document_api_client.dart';
import '../assembly/assembly_tree_model.dart' show AssemblyItemState;
import '../ai/ai_theme.dart' show AiPalette;
import 'assembly_tree_helpers.dart';
import 'component_context_menu.dart' show kEditAloneLabel;

/// One of the selected component's mates (C2): its row's label and state as the tree shows them, and what a tap does (select the mate and
/// reveal its row).
class AssemblyComponentMate {
  final String id;
  final String label;
  final AssemblyItemState state;
  final VoidCallback onTap;
  const AssemblyComponentMate({required this.id, required this.label, required this.state, required this.onTap});
}

/// Assembly lens component selection drawer - the assembly equivalent of
/// [SelectionListDrawer] for Part lens mesh entity selection. Shows the
/// currently-selected component with action buttons (Move, Fix/Float, Delete)
/// in a draggable sheet matching Part lens UI conventions.
class AssemblyComponentSelectionDrawer extends StatelessWidget {
  final OccurrenceDto selectedComponent;

  /// The human-readable name to show (see `occurrenceDisplayName`); defaults to the one derived from the component alone.
  final String? displayName;
  /// Move, Fix / Float and Delete; null leaves the button out (C2: a component nested below the focused level is not edited from here).
  final VoidCallback? onMove;
  final VoidCallback? onFixFloat;
  final VoidCallback? onDelete;

  /// C2 (#7): the component's mates on its parent level (mates whose references' top occurrence is this component), each with its state.
  /// Empty lists nothing; null says they are being read.
  final List<AssemblyComponentMate>? mates;

  /// Edit Alone for the selected component (the first button). Null hides it (inside Edit Alone, or when the screen
  /// cannot start one).
  final VoidCallback? onEditAlone;

  /// Zoom to the component (B4: phone landscape has no selection bar in the tree; the drawer gains its Zoom). Null hides it.
  final VoidCallback? onZoom;

  /// Bug report 2026-10-14, item 6: the only way out used to be tapping empty
  /// space. When non-null, an X ("Clear selection") closes the drawer by
  /// clearing the selection.
  final VoidCallback? onClose;

  static const double _fabColumnClearance = 72;

  const AssemblyComponentSelectionDrawer({
    super.key,
    required this.selectedComponent,
    this.displayName,
    this.onMove,
    this.onFixFloat,
    this.onDelete,
    this.mates = const [],
    this.onEditAlone,
    this.onZoom,
    this.onClose,
  });

  @override
  Widget build(BuildContext context) {
    final componentName = displayName ?? occurrenceDisplayName([selectedComponent], 0);

    // Desktop layout (D6): a block docked under the tree in the left pane, not a sheet over the viewport.
    if (LayoutModeScope.isDesktop(context)) {
      final theme = Theme.of(context);
      return Material(
        key: const ValueKey('docked-component-selection'),
        color: theme.colorScheme.surfaceContainerLow,
        child: Container(
          padding: const EdgeInsets.fromLTRB(16, 8, 8, 12),
          decoration: BoxDecoration(border: Border(top: BorderSide(color: theme.colorScheme.outlineVariant))),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              Row(
                children: [
                  const Icon(Icons.view_in_ar_outlined, size: 18),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(componentName, style: theme.textTheme.titleSmall, maxLines: 1, overflow: TextOverflow.ellipsis),
                  ),
                  if (onClose != null)
                    IconButton(
                      tooltip: 'Clear selection',
                      icon: const Icon(Icons.close, size: 18),
                      visualDensity: VisualDensity.compact,
                      onPressed: onClose,
                    ),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  if (onEditAlone != null)
                    FilledButton.tonal(
                      key: const ValueKey('component-edit-alone'),
                      onPressed: onEditAlone,
                      child: const Text(kEditAloneLabel),
                    ),
                  if (onMove != null) FilledButton.tonal(onPressed: onMove, child: const Text('Move')),
                  if (onFixFloat != null)
                    FilledButton.tonal(onPressed: onFixFloat, child: Text(selectedComponent.fixed ? 'Float' : 'Fix')),
                  if (onDelete != null) FilledButton.tonal(onPressed: onDelete, child: const Text('Delete')),
                ],
              ),
              ..._mateList(context, dense: true),
            ],
          ),
        ),
      );
    }

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
                              if (onClose != null)
                                IconButton(
                                  tooltip: 'Clear selection',
                                  icon: const Icon(Icons.close, size: 20),
                                  visualDensity: VisualDensity.compact,
                                  onPressed: onClose,
                                ),
                            ],
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 8,
                            runSpacing: 8,
                            children: [
                              if (onEditAlone != null)
                                FilledButton.tonal(
                                  key: const ValueKey('component-edit-alone'),
                                  onPressed: onEditAlone,
                                  child: const Text(kEditAloneLabel),
                                ),
                              if (onZoom != null)
                                FilledButton.tonal(key: const ValueKey('component-zoom'), onPressed: onZoom, child: const Text('Zoom')),
                              if (onMove != null) FilledButton.tonal(onPressed: onMove, child: const Text('Move')),
                              if (onFixFloat != null)
                                FilledButton.tonal(
                                  onPressed: onFixFloat,
                                  child: Text(selectedComponent.fixed ? 'Float' : 'Fix'),
                                ),
                              if (onDelete != null)
                                FilledButton.tonal(
                                  onPressed: onDelete,
                                  child: const Text('Delete'),
                                ),
                            ],
                          ),
                          ..._mateList(context, dense: false),
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

/// A mate's state in words, for the drawer's list (null: nothing to say).
String? assemblyItemStateText(AssemblyItemState state) => switch (state) {
      AssemblyItemState.lost => 'Lost a face',
      AssemblyItemState.held => 'Check this mate',
      AssemblyItemState.broken => 'Broken',
      AssemblyItemState.near => 'Within tolerance',
      AssemblyItemState.suppressed => 'Suppressed',
      AssemblyItemState.none => null,
    };

extension on AssemblyComponentSelectionDrawer {
  /// The selected component's mates: a heading, then one row each (its state's colour and words); a tap selects the mate.
  List<Widget> _mateList(BuildContext context, {required bool dense}) {
    final list = mates;
    final theme = Theme.of(context);
    if (list != null && list.isEmpty) return const [];
    final palette = AiPalette.of(context);
    return [
      const SizedBox(height: 8),
      Text(list == null ? 'Mates' : 'Mates (${list.length})',
          key: const ValueKey('component-mates-heading'), style: theme.textTheme.labelMedium?.copyWith(color: theme.colorScheme.onSurfaceVariant)),
      if (list == null)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text('Reading mates...', key: const ValueKey('component-mates-reading'), style: theme.textTheme.bodySmall),
        )
      else
        for (final m in list)
          InkWell(
            key: ValueKey('component-mate:${m.id}'),
            onTap: m.onTap,
            child: SizedBox(
              height: dense ? 32 : 44,
              child: Row(
                children: [
                  Icon(
                    m.state.isError || m.state.isWarning ? Icons.warning_amber_rounded : Icons.link,
                    size: 18,
                    color: m.state.isError
                        ? theme.colorScheme.error
                        : m.state.isWarning
                            ? palette.warning
                            : theme.colorScheme.onSurfaceVariant,
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Opacity(
                      opacity: m.state == AssemblyItemState.suppressed ? 0.45 : 1.0,
                      child: Text.rich(
                        TextSpan(children: [
                          TextSpan(text: m.label),
                          if (assemblyItemStateText(m.state) case final text?)
                            TextSpan(text: '  $text', style: TextStyle(fontSize: 12, color: theme.colorScheme.onSurfaceVariant)),
                        ]),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
    ];
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
