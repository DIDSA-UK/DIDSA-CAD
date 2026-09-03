import 'package:flutter/material.dart';

import 'selection_hit_test.dart';
import 'svg_icon.dart';

/// Bug report ("if one body is entirely inside another body, it cannot be
/// selected" - user-requested SOLIDWORKS-style "Select Other"): shown when
/// `PartViewport.onSelectOtherRequested` fires from a click-then-
/// click-and-hold gesture. Lists every [HoverHit] `hitTestAllCandidates`
/// found at that screen position (nearest first) so the user can reach one
/// the ordinary single-nearest-hit pick can never reach on its own - most
/// notably a Body fully enclosed inside another, which `hitTestBodies` can
/// never resolve from any camera angle (see that function's own doc
/// comment).
///
/// [onHighlight] fires as the user hovers/focuses a row, and once more with
/// `null` after the sheet closes - the caller (`PartScreen`) is expected to
/// feed it straight into `PartViewport.highlightOverride` so the
/// corresponding entity lights up live in the 3D view before the user
/// commits to it, mirroring SOLIDWORKS' own "Select Other" popup.
Future<void> showSelectOtherSheet(
  BuildContext context, {
  required List<HoverHit> candidates,
  required Map<String, String> bodyNames,
  required void Function(SelectionEntityRef entity) onSelect,
  required void Function(SelectionEntityRef? entity) onHighlight,
}) async {
  await showModalBottomSheet<void>(
    context: context,
    builder: (context) => _SelectOtherSheet(
      candidates: candidates,
      bodyNames: bodyNames,
      onSelect: onSelect,
      onHighlight: onHighlight,
    ),
  );
  onHighlight(null);
}

class _SelectOtherSheet extends StatelessWidget {
  final List<HoverHit> candidates;
  final Map<String, String> bodyNames;
  final void Function(SelectionEntityRef entity) onSelect;
  final void Function(SelectionEntityRef? entity) onHighlight;

  const _SelectOtherSheet({
    required this.candidates,
    required this.bodyNames,
    required this.onSelect,
    required this.onHighlight,
  });

  @override
  Widget build(BuildContext context) {
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 6),
            child: _DragHandle(),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
            child: Align(
              alignment: Alignment.centerLeft,
              child: Text('Select Other', style: Theme.of(context).textTheme.titleMedium),
            ),
          ),
          Flexible(
            child: ListView.builder(
              shrinkWrap: true,
              itemCount: candidates.length,
              itemBuilder: (context, index) {
                final entity = candidates[index].entity;
                return MouseRegion(
                  onEnter: (_) => onHighlight(entity),
                  onExit: (_) => onHighlight(null),
                  child: ListTile(
                    dense: true,
                    leading: _iconFor(entity.kind),
                    title: Text(_titleFor(entity)),
                    onTap: () {
                      Navigator.of(context).pop();
                      onSelect(entity);
                    },
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // Mirrors `SelectionListDrawer`'s own `_iconFor`/`_labelFor`/`_titleFor` -
  // kept as this widget's own small copy rather than a shared export, since
  // this sheet only ever needs a lean subset (no removal affordance, no
  // sort order) and the two lists are never shown side by side.
  Widget _iconFor(SelectionEntityKind kind) {
    switch (kind) {
      case SelectionEntityKind.face:
        return const SvgIcon('assets/icons/viewport/selection_face.svg');
      case SelectionEntityKind.edge:
        return const SvgIcon('assets/icons/viewport/selection_edge.svg');
      case SelectionEntityKind.vertex:
        return const SvgIcon('assets/icons/viewport/selection_vertex.svg');
      case SelectionEntityKind.body:
        return const SvgIcon('assets/icons/viewport/selection_body.svg');
      case SelectionEntityKind.sketchPoint:
        return const SvgIcon('assets/icons/viewport/selection_sketch_point.svg');
      case SelectionEntityKind.sketchLine:
        return const Icon(Icons.timeline);
      case SelectionEntityKind.sketchCircle:
      case SelectionEntityKind.sketchArc:
      case SelectionEntityKind.sketchEllipse:
      case SelectionEntityKind.sketchEllipseArc:
      case SelectionEntityKind.sketchSpline:
        return const SvgIcon('assets/icons/viewport/selection_sketch_circle.svg');
      case SelectionEntityKind.sketchText:
        return const SvgIcon('assets/icons/sketch_tools/sketch_tool_text.svg');
      case SelectionEntityKind.referencePlane:
      case SelectionEntityKind.createPlane:
        return const SvgIcon('assets/icons/viewport/selection_plane.svg');
      case SelectionEntityKind.sketchPatternMirrorInstance:
        return const SvgIcon('assets/icons/feature/feature_pattern.svg');
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
      case SelectionEntityKind.sketchPoint:
        return 'Sketch Point';
      case SelectionEntityKind.sketchLine:
        return 'Sketch Line';
      case SelectionEntityKind.sketchCircle:
        return 'Sketch Circle';
      case SelectionEntityKind.sketchArc:
        return 'Sketch Arc';
      case SelectionEntityKind.sketchEllipse:
        return 'Sketch Ellipse';
      case SelectionEntityKind.sketchEllipseArc:
        return 'Sketch Ellipse Arc';
      case SelectionEntityKind.sketchSpline:
        return 'Sketch Spline';
      case SelectionEntityKind.sketchText:
        return 'Sketch Text';
      case SelectionEntityKind.referencePlane:
      case SelectionEntityKind.createPlane:
        return 'Plane';
      case SelectionEntityKind.sketchPatternMirrorInstance:
        return 'Pattern/Mirror';
    }
  }

  String _titleFor(SelectionEntityRef entity) {
    if (entity.kind == SelectionEntityKind.body) {
      final id = entity.bodyId;
      return bodyNames[id] ?? 'Body ${id.length > 8 ? id.substring(0, 8) : id}';
    }
    if (entity.kind == SelectionEntityKind.sketchPoint ||
        entity.kind == SelectionEntityKind.sketchLine ||
        entity.kind == SelectionEntityKind.sketchCircle ||
        entity.kind == SelectionEntityKind.sketchArc ||
        entity.kind == SelectionEntityKind.sketchEllipse ||
        entity.kind == SelectionEntityKind.sketchEllipseArc ||
        entity.kind == SelectionEntityKind.sketchSpline ||
        entity.kind == SelectionEntityKind.sketchText) {
      final id = entity.sketchEntityId;
      return '${_labelFor(entity.kind)} #${id.length > 8 ? id.substring(0, 8) : id}';
    }
    return '${_labelFor(entity.kind)} #${entity.id}';
  }
}

/// A small grab-handle bar hinting that the sheet above is draggable-away -
/// mirrors `SelectionListDrawer`'s own private `_DragHandle` (purely
/// decorative, no gesture handling of its own).
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
