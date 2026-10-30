import 'package:flutter/material.dart';

import 'svg_icon.dart';
import '../layout/adaptive_sheet.dart';

/// Actions available from the "Add" FAB's second-level Feature picker.
/// [extrude], (C3) [plane], (on-device feedback) [fillet], (Prompt E)
/// [chamfer], (Prompt F) [revolve], and [sweep] are all wired to a real
/// flow.
enum FeaturePickerAction {
  extrude,
  revolve,
  sweep,
  loft,
  plane,
  surface,
  // Phase 1 surfacing package: five new surface-producing tools, all
  // grouped into the existing "Surfacing" section alongside [surface]
  // ("Extrude Surface") below.
  planarSurface,
  revolveSurface,
  sweptSurface,
  loftSurface,
  ruledSurface,
  // Phase 2 surfacing package: Knit Surfaces/Offset Surface join the same
  // "Surfacing" section (both surface-producing); Thicken/Solid from
  // Surfaces get their own new "From Surfaces" section below it instead
  // (both solid-producing/surface-consuming - see that section's own doc
  // comment for why they don't belong in "Surfacing" itself).
  knitSurface,
  offsetSurface,
  thicken,
  solidFromSurfaces,
  fillet,
  chamfer,
  mirror,
  pattern,
  // Curve features: a Helix or an Intersection curve, each its own guided
  // flow (`part_screen.dart`'s own `_startHelix`/`_startIntersectionCurve`)
  // opening [CurvePanel] pre-set to the matching [CurveMode] - grouped with
  // "Sketch-based" since a Curve feature is a construction geometry source
  // in the same family, not with "Reference" (Plane) or "Surfacing".
  helix,
  intersectionCurve,
  // A Spring (a compression spring as one Body, from its numbers) - next to Helix, its nearest
  // relative; `part_screen.dart`'s `_startSpring` opens [SpringPanel].
  spring,
  // A Fill Surface (grouped with "Surfacing" - it produces a Surface, same
  // as every other entry there) - opens [FillSurfacePanel] from whatever
  // 2-4 boundary-capable entities (Sketch lines/arcs/circles/ellipses/
  // splines, or existing Curve features) are already selected.
  fillSurface,
  // Boolean family, first entry.
  merge,
  // Boolean family, Subtract/Common.
  subtract,
  common,
  // Boolean family, fourth/last entry.
  split,
  // Direct Editing family - all five were previously ambient-entry-only
  // (`selection_actions.dart`'s `contextActionsFor`, reachable only once a
  // Body/face was already selected) with no guided "Add" FAB entry at all;
  // each now starts the same picking flow that entry point already has
  // (`part_screen.dart`'s own `_start*Picker` functions), just reachable
  // from here first too.
  deleteBody,
  scaleBody,
  moveBody,
  deleteFace,
  moveFace,
  // Shell: body-first face-picking Direct Edit tool - opens the Shell panel
  // straight away and the faces to open are picked from inside it.
  shell,
}

/// Shows the fly-up bottom sheet listing every feature type the "Add" FAB's
/// Feature entry offers - same drag-handle/rounded-top-corner shape as
/// [showPlaneContextSheet], so both Stage 19b fly-ups feel consistent.
///
/// Grouped into collapsible sections (mirrors [FeatureTreePanel]'s own
/// Bodies/Planes `ExpansionTile` grouping - `_buildGroupedTree` - rather
/// than a flat list, now that this sheet has grown past a handful of rows):
/// Sketch-based (Extrude/Revolve/Sweep/Loft), Reference (Plane), Surfacing
/// (Extrude Surface - its own section, split out from Reference, since it's
/// also reachable via a long-press-on-Sketch entry of the same name - see
/// `feature_context_menu.dart`'s `showSurface` - and reads oddly grouped
/// alongside a pure reference Plane), and Direct Edit (Delete Body/Scale
/// Body/Move Body/Delete Face/Move Face - all five previously ambient-
/// entry-only, with no guided "Add" FAB entry at all before this) on the
/// left; Modify (Fillet/Chamfer), Repeat (Mirror/Pattern - not titled
/// "Pattern" itself, since that collided with the "Pattern" entry it
/// contains - see that section's own doc comment), and Combine (Merge/
/// Subtract/Common/Split, all four real/enabled - see [_CombineSection]) on
/// the right.
///
/// On-device feedback: every section now starts collapsed (`initiallyExpanded:
/// false`, previously only Combine did) - with several sections, opening the
/// sheet already fully expanded showed more rows than fit most viewports at
/// once. Bug fix: laid out as two independently-scrolling columns (a `Row`
/// of two `Expanded` `SingleChildScrollView`s, left: Sketch-based/Reference/
/// Surfacing/Direct Edit, right: Modify/Repeat/Combine) rather than one long
/// vertical list - expanding a section in one column no longer pushes the
/// other column's rows off-screen or resets its scroll position; Direct Edit
/// joined the left column specifically to keep both columns' own row counts
/// roughly balanced (right already had Modify/Repeat/Combine's own 8 rows
/// across 3 sections). The two-column area gets a bounded height (a fraction
/// of the screen) so each column's
/// own [SingleChildScrollView] has something concrete to scroll within.
Future<FeaturePickerAction?> showFeaturePickerSheet(BuildContext context) {
  return showAdaptiveSheet<FeaturePickerAction>(
    context: context,
    // C3: added a sixth entry (Plane) - scroll-controlled so this sheet can
    // grow past its old fixed-fraction default height instead of clipping/
    // overflowing on a short viewport (a small phone in landscape, or a
    // split-screen window) the way a fixed-size six-row sheet otherwise
    // risks doing.
    isScrollControlled: true,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
    builder: (context) {
      final columnAreaHeight = MediaQuery.sizeOf(context).height * 0.6;
      Widget column(List<FeatureGroupSpec> groups) => Expanded(
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (final group in groups) _FeatureSection(group: group),
                  const SizedBox(height: 8),
                ],
              ),
            ),
          );
      return SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Padding(
              padding: EdgeInsets.only(top: 8),
              child: _DragHandle(),
            ),
            SizedBox(
              height: columnAreaHeight,
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  column(kFeatureGroups.sublist(0, kFeaturePickerLeftColumnGroups)),
                  column(kFeatureGroups.sublist(kFeaturePickerLeftColumnGroups)),
                ],
              ),
            ),
          ],
        ),
      );
    },
  );
}

/// One feature the picker (and the phone Start menu's Features tab) offers.
class FeatureEntrySpec {
  const FeatureEntrySpec(this.label, this.icon, this.action);

  final String label;
  final String icon;
  final FeaturePickerAction action;
}

/// A titled run of [FeatureEntrySpec]s.
class FeatureGroupSpec {
  const FeatureGroupSpec(this.title, this.entries);

  final String title;
  final List<FeatureEntrySpec> entries;
}

/// How many of [kFeatureGroups] the picker puts in its left column (the rest go right).
const int kFeaturePickerLeftColumnGroups = 5;

/// Every feature, grouped. The one table behind [showFeaturePickerSheet] and the Start menu's Features tab
/// (`docs/touch-viewport-ux-plan.md` section 3), so the two cannot drift. Notes on the groups:
///
/// - "Surfacing" holds every surface-producing tool (Extrude Surface was split out of "Reference"; Revolve / Swept / Loft
///   Surface reuse their solid sibling's icon, Planar and Ruled Surface have their own); "From Surfaces" is the mirror image
///   (solid-producing, surface-consuming), kept apart so "Surfacing" keeps meaning "produces a Surface".
/// - "Direct Edit" was ambient-entry-only before the picker listed it; each entry starts the same picking flow
///   `selection_actions.dart`'s `contextActionsFor` buttons trigger.
/// - "Repeat" is not called "Pattern": that collided with the "Pattern" entry it contains (`find.text('Pattern')` matched
///   both the header and the row).
const List<FeatureGroupSpec> kFeatureGroups = [
  FeatureGroupSpec('Sketch-based', [
    FeatureEntrySpec('Extrude', 'assets/icons/feature/feature_extrude.svg', FeaturePickerAction.extrude),
    FeatureEntrySpec('Revolve', 'assets/icons/feature/feature_revolve.svg', FeaturePickerAction.revolve),
    FeatureEntrySpec('Sweep', 'assets/icons/feature/feature_sweep.svg', FeaturePickerAction.sweep),
    FeatureEntrySpec('Loft', 'assets/icons/feature/feature_loft.svg', FeaturePickerAction.loft),
    FeatureEntrySpec('Helix', 'assets/icons/feature/feature_sweep.svg', FeaturePickerAction.helix),
    FeatureEntrySpec('Intersection Curve', 'assets/icons/feature/feature_sweep.svg', FeaturePickerAction.intersectionCurve),
    FeatureEntrySpec('Spring', 'assets/icons/feature/feature_spring.svg', FeaturePickerAction.spring),
  ]),
  FeatureGroupSpec('Reference', [
    FeatureEntrySpec('Plane', 'assets/icons/feature/feature_plane.svg', FeaturePickerAction.plane),
  ]),
  FeatureGroupSpec('Surfacing', [
    FeatureEntrySpec('Extrude Surface', 'assets/icons/feature/feature_surface.svg', FeaturePickerAction.surface),
    FeatureEntrySpec('Planar Surface', 'assets/icons/feature/feature_planar_surface.svg', FeaturePickerAction.planarSurface),
    FeatureEntrySpec('Revolve Surface', 'assets/icons/feature/feature_revolve.svg', FeaturePickerAction.revolveSurface),
    FeatureEntrySpec('Swept Surface', 'assets/icons/feature/feature_sweep.svg', FeaturePickerAction.sweptSurface),
    FeatureEntrySpec('Loft Surface', 'assets/icons/feature/feature_loft.svg', FeaturePickerAction.loftSurface),
    FeatureEntrySpec('Ruled Surface', 'assets/icons/feature/feature_ruled_surface.svg', FeaturePickerAction.ruledSurface),
    FeatureEntrySpec('Knit Surfaces', 'assets/icons/feature/feature_knit.svg', FeaturePickerAction.knitSurface),
    FeatureEntrySpec('Offset Surface', 'assets/icons/feature/feature_offset_surface.svg', FeaturePickerAction.offsetSurface),
    FeatureEntrySpec('Fill Surface', 'assets/icons/feature/feature_surface.svg', FeaturePickerAction.fillSurface),
  ]),
  FeatureGroupSpec('From Surfaces', [
    FeatureEntrySpec('Thicken', 'assets/icons/feature/feature_thicken.svg', FeaturePickerAction.thicken),
    FeatureEntrySpec('Solid from Surfaces', 'assets/icons/feature/feature_solid_from_surfaces.svg', FeaturePickerAction.solidFromSurfaces),
  ]),
  FeatureGroupSpec('Direct Edit', [
    FeatureEntrySpec('Delete Body', 'assets/icons/feature/feature_delete_body.svg', FeaturePickerAction.deleteBody),
    FeatureEntrySpec('Scale Body', 'assets/icons/feature/feature_scale.svg', FeaturePickerAction.scaleBody),
    FeatureEntrySpec('Move/Copy Body', 'assets/icons/feature/feature_move_body.svg', FeaturePickerAction.moveBody),
    FeatureEntrySpec('Delete Face', 'assets/icons/feature/feature_delete_face.svg', FeaturePickerAction.deleteFace),
    FeatureEntrySpec('Move Face', 'assets/icons/feature/feature_move_face.svg', FeaturePickerAction.moveFace),
    FeatureEntrySpec('Shell', 'assets/icons/feature/feature_shell.svg', FeaturePickerAction.shell),
  ]),
  FeatureGroupSpec('Modify', [
    FeatureEntrySpec('Fillet', 'assets/icons/feature/feature_fillet.svg', FeaturePickerAction.fillet),
    FeatureEntrySpec('Chamfer', 'assets/icons/feature/feature_chamfer.svg', FeaturePickerAction.chamfer),
  ]),
  FeatureGroupSpec('Repeat', [
    FeatureEntrySpec('Mirror', 'assets/icons/feature/feature_mirror.svg', FeaturePickerAction.mirror),
    FeatureEntrySpec('Pattern', 'assets/icons/feature/feature_pattern.svg', FeaturePickerAction.pattern),
  ]),
  FeatureGroupSpec('Combine', [
    FeatureEntrySpec('Merge', 'assets/icons/feature/feature_merge.svg', FeaturePickerAction.merge),
    FeatureEntrySpec('Subtract', 'assets/icons/feature/feature_merge.svg', FeaturePickerAction.subtract),
    FeatureEntrySpec('Common', 'assets/icons/feature/feature_merge.svg', FeaturePickerAction.common),
    FeatureEntrySpec('Split', 'assets/icons/feature/feature_split.svg', FeaturePickerAction.split),
  ]),
];

/// One collapsible group of Feature entries - mirrors [FeatureTreePanel]'s
/// own Bodies/Planes `ExpansionTile` convention (dense, compact visual
/// density, a section-weight title) rather than inventing a new grouping
/// widget. Every section starts collapsed: opened fully expanded, the
/// sheet showed more rows than fit most viewports at once.
class _FeatureSection extends StatelessWidget {
  final FeatureGroupSpec group;

  const _FeatureSection({required this.group});

  @override
  Widget build(BuildContext context) {
    return ExpansionTile(
      initiallyExpanded: false,
      dense: true,
      visualDensity: VisualDensity.compact,
      title: Text(
        group.title,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
      ),
      children: [
        for (final entry in group.entries)
          ListTile(
            leading: SvgIcon(entry.icon),
            title: Text(entry.label),
            onTap: () => Navigator.of(context).pop(entry.action),
          ),
      ],
    );
  }
}

class _DragHandle extends StatelessWidget {
  const _DragHandle();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 32,
      height: 4,
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.3),
        borderRadius: BorderRadius.circular(2),
      ),
    );
  }
}
