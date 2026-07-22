import 'dart:async';
import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart' show BodyMeshDto;
import '../api/sketch_api_client.dart'
    show ApiException, ArcDto, CircleDto, EllipseDto, LineDto, PointDto, SketchDto, SplineDto;
import '../didsa_logo_button.dart';
import '../viewport3d/part_viewport.dart';
import '../viewport3d/reference_planes.dart';
import '../viewport3d/render_mode.dart';
import '../viewport3d/selection_filter.dart' show SelectionFilterState;
import '../viewport3d/selection_hit_test.dart' show SelectionEntityKind, SelectionEntityRef;
import '../viewport3d/sketch_geometry_3d.dart';
import '../viewport3d/svg_icon.dart';
import '../viewport3d/view_prefs_sheets.dart';
import '../viewport3d/view_preferences.dart';
import 'sketch_canvas.dart';
import 'sketch_construction_method_bar.dart';
import 'sketch_controller.dart';
import 'sketch_dimension_bar.dart';
import 'sketch_offset_bar.dart';
import 'sketch_ribbon.dart';
import 'sketch_speed_dial.dart';
import 'sketcher_preferences.dart';

/// Phase 4.1/4.2: converts [controller]'s live points into the
/// [PointDto]/[LineDto]/[CircleDto] shapes [sketchGeometry3DFrom] expects -
/// needed because [SketchController]'s own `SketchPointView`/`SketchLineView`/
/// `SketchCircleView` are a distinct, unsaved-state-oriented set of types
/// that don't carry the `length`/`radius` fields those DTOs do (the backend
/// computes those; the live client-side views don't store them), so they're
/// recomputed here via plain distance formulas.
/// On-device feedback: a Circle's/Polygon's own centre Point used to be
/// converted (and so rendered) unconditionally, every frame - now excluded
/// unless hover-revealed (`SketchController.revealedShapeCenterPointId`),
/// selected, actively grabbed, or the live in-progress anchor of that same
/// draw tool, mirroring `sketch_canvas.dart`'s own equivalent gate exactly
/// (see `revealedShapeCenterPointId`'s own doc comment for why).
List<PointDto> _pointDtosFrom(SketchController controller) {
  final shapeCenterIds = <String>{
    for (final circle in controller.circles.values) circle.centerPointId,
    for (final polygon in controller.polygons.values) polygon.centerPointId,
  };
  final revealedId = controller.revealedShapeCenterPointId;
  bool isSelected(String id) =>
      controller.selectionSet.any((s) => s.kind == SelectionKind.point && s.id == id) ||
      controller.dimensionSelection.any((s) => s.kind == SelectionKind.point && s.id == id);
  bool isInProgressAnchor(String id) =>
      (controller.circleInProgress && id == controller.circleCenterPointId) ||
      (controller.polygonInProgress && id == controller.polygonCenterPointId);
  return [
    for (final p in controller.points.values)
      if (!shapeCenterIds.contains(p.id) ||
          p.id == revealedId ||
          isSelected(p.id) ||
          controller.draggingPointId == p.id ||
          isInProgressAnchor(p.id))
        PointDto(id: p.id, x: p.x, y: p.y),
  ];
}

double _sketchPointDistance(SketchPointView a, SketchPointView b) {
  final dx = b.x - a.x;
  final dy = b.y - a.y;
  return math.sqrt(dx * dx + dy * dy);
}

List<LineDto> _lineDtosFrom(SketchController controller) => [
      for (final line in controller.lines.values)
        if (controller.points[line.startPointId] != null && controller.points[line.endPointId] != null)
          LineDto(
            id: line.id,
            startPointId: line.startPointId,
            endPointId: line.endPointId,
            length: _sketchPointDistance(
              controller.points[line.startPointId]!,
              controller.points[line.endPointId]!,
            ),
            construction: line.construction,
          ),
    ];

/// Bug fix: Orbit View's own Sketch-geometry render used to only convert
/// Points/Lines/Circles, silently dropping Arc/Ellipse/Spline - this and
/// [_ellipseDtosFrom]/[_splineDtosFrom] close that gap, mirroring the same
/// fix in `part_screen.dart`'s main 3D Part viewport - see
/// [sketchGeometry3DFrom]'s own doc comment.
List<ArcDto> _arcDtosFrom(SketchController controller) => [
      for (final arc in controller.arcs.values)
        if (controller.points[arc.centerPointId] != null && controller.points[arc.startPointId] != null)
          ArcDto(
            id: arc.id,
            centerPointId: arc.centerPointId,
            startPointId: arc.startPointId,
            endPointId: arc.endPointId,
            radius: _sketchPointDistance(
              controller.points[arc.centerPointId]!,
              controller.points[arc.startPointId]!,
            ),
            construction: arc.construction,
          ),
    ];

List<EllipseDto> _ellipseDtosFrom(SketchController controller) => [
      for (final ellipse in controller.ellipses.values)
        if (controller.points[ellipse.centerPointId] != null && controller.points[ellipse.majorPointId] != null)
          EllipseDto(
            id: ellipse.id,
            centerPointId: ellipse.centerPointId,
            majorPointId: ellipse.majorPointId,
            majorPointNegId: ellipse.majorPointNegId,
            minorPointId: ellipse.minorPointId,
            minorPointNegId: ellipse.minorPointNegId,
            majorAxisLineId: ellipse.majorAxisLineId,
            minorAxisLineId: ellipse.minorAxisLineId,
            majorRadius: _sketchPointDistance(
              controller.points[ellipse.centerPointId]!,
              controller.points[ellipse.majorPointId]!,
            ),
            minorRadius: ellipse.minorRadius,
            rotation: math.atan2(
              controller.points[ellipse.majorPointId]!.y - controller.points[ellipse.centerPointId]!.y,
              controller.points[ellipse.majorPointId]!.x - controller.points[ellipse.centerPointId]!.x,
            ),
            construction: ellipse.construction,
          ),
    ];

List<SplineDto> _splineDtosFrom(SketchController controller) => [
      for (final spline in controller.splines.values)
        SplineDto(
          id: spline.id,
          throughPointIds: spline.throughPointIds,
          controlPointIds: spline.controlPointIds,
          construction: spline.construction,
        ),
    ];

List<CircleDto> _circleDtosFrom(SketchController controller) => [
      for (final circle in controller.circles.values)
        if (controller.points[circle.centerPointId] != null && controller.points[circle.radiusPointId] != null)
          CircleDto(
            id: circle.id,
            centerPointId: circle.centerPointId,
            radiusPointId: circle.radiusPointId,
            radius: _sketchPointDistance(
              controller.points[circle.centerPointId]!,
              controller.points[circle.radiusPointId]!,
            ),
            construction: circle.construction,
          ),
    ];

/// The 2D sketch screen: chained line/circle sketching against the live
/// backend, against a single Sketch. By default it creates a brand-new
/// Sketch on startup (see [SketchController.ensureSketch]); when
/// [adoptSketchId] is given instead - the case when this is pushed from
/// [PartScreen] for an existing SketchFeature - it initializes from that
/// already-created Sketch instead (see [SketchController.adoptSketch]).
class SketchScreen extends StatefulWidget {
  /// Overridable for tests, so they don't talk to the real backend.
  final SketchController? controller;

  /// If set, this screen edits the Sketch with this id instead of creating
  /// a new one.
  final String? adoptSketchId;

  /// The standalone "2D Drawing" tool (floor plans and other Part-free
  /// drawings, reached from the app's own chooser screen rather than
  /// [PartScreen]) - true here means two things: [_loadInitialOrbitViewPreference]
  /// never auto-enters Orbit View regardless of [SketcherPreferences.
  /// use3DSketcher] (that default is for in-Part sketching, not a flat
  /// drafting tool with no Bodies/planes to show), and the hamburger menu
  /// gains Save/Open entries for this Sketch's own local file, in place of
  /// the Part-level native file format a Part-anchored Sketch relies on
  /// instead (see [_saveStandaloneSketch]/[_openStandaloneSketch]).
  final bool standalone;

  /// Stage 12 item 9: the existing solid's mesh edges, already projected
  /// onto this Sketch's plane by the caller ([PartScreen], which is the
  /// only place that has both the Part's mesh and the plane) - empty when
  /// there's nothing to show (e.g. an empty Part, or this screen reached
  /// outside [PartScreen] at all, such as in isolated tests).
  final List<((double, double), (double, double))> referenceGhostSegments;

  /// Phase 4.1/4.2: the same Part's Body meshes ([PartScreen]'s
  /// `_visibleBodies`), threaded in so the Orbit View toggle can show them
  /// shaded (not just [referenceGhostSegments]'s flat wireframe outline)
  /// behind the sketch's own geometry. Empty outside [PartScreen] (e.g.
  /// isolated tests), in which case the toggle simply shows no bodies.
  final List<BodyMeshDto> bodies;

  /// Sketcher-roadmap Phase 4.3 v1: [referenceGhostSegments]'s own pick
  /// targets - each existing Body vertex projected onto this Sketch's
  /// plane the same way, as `(bodyId, vertexIndex, x, y)` - so a dimension-
  /// mode tap near one can be resolved back to a real Body vertex and
  /// materialized as a Point (see [SketchController.
  /// pickReferenceGhostVertex]). Empty outside [PartScreen], same as
  /// [referenceGhostSegments].
  final List<(String, int, double, double)> referenceGhostVertices;

  /// Sketcher-roadmap Phase 4.3 v2: the whole-edge analogue of
  /// [referenceGhostVertices] - each existing Body edge's endpoints
  /// projected onto this Sketch's plane, as `(bodyId, edgeIndex,
  /// (startX,startY), (endX,endY))`, so a dimension-mode tap on the
  /// dashed ghost outline itself (not just one of its vertices) can be
  /// resolved back to a real Body edge and materialized as a Line (see
  /// [SketchController.pickReferenceGhostEdge]). Empty outside
  /// [PartScreen], same as [referenceGhostVertices].
  final List<(String, int, (double, double), (double, double))> referenceGhostEdges;

  /// Sketcher-roadmap Phase 4.3 v1: the owning Part's id and this Sketch's
  /// own SketchFeature id - both null unless this screen was opened from
  /// [PartScreen] (a bare Sketch reached via the standalone `/sketch` API,
  /// e.g. in isolated tests, has no Part/Bodies to reference at all).
  /// Threaded straight into [SketchController.adoptSketch] - see that
  /// method's own doc comment for why [pickReferenceGhostVertex] needs
  /// them.
  final String? documentPartId;
  final String? sketchFeatureId;

  /// On-device feedback (bug fix): this Sketch's own plane, fully oriented
  /// (flip/rotationQuarterTurns already applied - see [SketchPlaneBasis.
  /// oriented]/[SketchPlaneBasis.withOrientation]) - [PartScreen] already
  /// resolves this for a brand-new or re-opened Sketch either way (a fixed
  /// [ReferencePlaneKind] or a custom, Feature-anchored Plane), so it's
  /// threaded straight through here rather than re-derived. Lets Orbit View
  /// work for a custom-plane Sketch too, not just a fixed one - [_planeKind]
  /// alone (this Sketch's own `plane` API value) is null for a custom
  /// Plane, which used to silently make Orbit View (and, before it was
  /// removed, the old shaded-body backdrop) unreachable there entirely.
  /// Null outside [PartScreen] (e.g. isolated tests, or a fetch failure) -
  /// [_effectiveOrbitBasis] falls back to reconstructing a fixed plane's own
  /// basis from [_planeKind] in that case, same as before this existed.
  final SketchPlaneBasis? planeBasis;

  /// On-device feedback ("previously created sketches are not visible while
  /// orbiting, and should be - same as the Body hide/show button"): every
  /// other Sketch's already-resolved 3D geometry ([PartScreen]'s own
  /// `_visibleSketchGeometries`, which this Sketch's own entry is excluded
  /// from by the caller), threaded in as a static snapshot the same way
  /// [bodies] already is. Merged into [_embeddedSketchGeometries] and gated
  /// by the same [_referenceBodyHidden] toggle bodies use - "one toggle,
  /// give me a clear view of just the sketch I'm working on" now covers
  /// sibling sketches too, not just bodies. Empty outside [PartScreen], same
  /// as [bodies].
  final Map<String, SketchGeometry3D> otherSketchGeometries;

  const SketchScreen({
    super.key,
    this.controller,
    this.adoptSketchId,
    this.referenceGhostSegments = const [],
    this.referenceGhostVertices = const [],
    this.referenceGhostEdges = const [],
    this.bodies = const [],
    this.documentPartId,
    this.sketchFeatureId,
    this.planeBasis,
    this.otherSketchGeometries = const {},
    this.standalone = false,
  });

  @override
  State<SketchScreen> createState() => _SketchScreenState();
}

class _SketchScreenState extends State<SketchScreen> {
  late final SketchController _controller;

  /// Stage 12 item 9's Hide/Show Reference Body toggle - in-memory only,
  /// same as PartScreen's `_referencePlanesHidden`. Defaults to shown. On-
  /// device feedback: originally gated only `SketchCanvas`'s own projected
  /// ghost-wireframe overlay (2D canvas); now also gates the real body
  /// meshes `PartViewport` renders in Orbit View (`bodiesHidden`) - one
  /// toggle, "give me a clear view of just the sketch" either way.
  bool _referenceBodyHidden = false;

  /// Whether the hamburger menu panel (see [_buildMenuPanel]) is open -
  /// plain state instead of Flutter's built-in [Scaffold.drawer]/[Drawer],
  /// which is always full-screen height by construction with no way to
  /// bound it - see [_buildMenuPanel]'s doc comment for why that mattered.
  bool _menuOpen = false;

  /// Stage 23f's View submenu controls - all in-memory only/session-only
  /// per the brief, with no `shared_preferences` persistence (unlike
  /// `viewport3d`'s analogous `ViewPreferences`).
  bool _constraintLabelsVisible = true;
  Color _canvasColor = SketchCanvas.defaultColor;

  /// Phase 4.2's Orbit View toggle: look-only, 2D editing stays disabled
  /// while active (see [_buildBaseLayer]'s doc comment). Session-only, same
  /// as the other view-preference fields above.
  bool _orbitViewActive = false;

  /// P19 on-device feedback: "the orbit button is supposed to swap between
  /// cursor control and orbit mode" - the FAB that used to enter/exit Orbit
  /// View outright (see the removed `_exitOrbitView`/`_enterOrbitView`'s own
  /// old doc comments in git history) is repurposed to toggle *this* once
  /// already inside Orbit View, rather than leaving it. True (the default
  /// on every fresh [_enterOrbitView]) drives [PartViewport]'s P16-P18
  /// cursor+ghost+commit interaction model (single-finger drag moves the
  /// draw/select cursor); false reverts [PartViewport] to plain camera
  /// orbiting with immediate tap-to-place/tap-to-select - exactly its
  /// pre-cursor-retrofit behaviour (single-finger drag orbits, a tap hits
  /// [_handleEmbeddedSketchTap]/[_handleEmbeddedSketchEntityTap] straight
  /// away) - so switching to Orbit sub-mode is a real "look around freely"
  /// mode, not merely a relabelled cursor mode. [SketcherPreferences.
  /// use3DSketcher] (device-wide, in Settings) is now the only way back to
  /// the flat 2D canvas - accepted deliberately in place of a live
  /// mid-session exit, since this FAB no longer offers one.
  bool _orbitCursorActive = true;

  /// Lets [_returnOrbitToDefaultView] drive the embedded [PartViewport]'s
  /// own [PartViewportState.animateToPlane] - the only way to control its
  /// internally-owned [OrbitCamera] from outside (see
  /// `viewport3d/orbit_camera.dart`: no camera is ever injectable).
  final GlobalKey<PartViewportState> _orbitViewportKey = GlobalKey<PartViewportState>();

  /// On-device feedback: bodies are no longer shown behind the flat 2D
  /// canvas at all (see [_buildBaseLayer]'s own doc comment for why - a
  /// perspective-camera backdrop synced to an orthographic 2D canvas is a
  /// fundamentally unfixable mismatch, since `flutter_scene` has no
  /// orthographic camera) - Orbit View is now the only place a Sketch's
  /// real Body geometry is shown. [_orbitRenderMode]/[_orbitBodyColourHex]/
  /// [_orbitBodyOpacity] are Orbit View's own View preferences (see
  /// [_build3DViewMenu]), session-only like the 2D canvas's own view
  /// preferences above. [_orbitRenderMode] defaults to `shadedWithEdges`
  /// (on-device feedback: edges should be visible by default).
  /// [_orbitBodyOpacity] defaults to 4.1's "~25% transparent" ask,
  /// overriding [ViewPreferences.defaultBodyOpacity]'s `1.0` rather than
  /// reusing the Part viewport's own persisted preference.
  ViewportRenderMode _orbitRenderMode = ViewportRenderMode.shadedWithEdges;
  String _orbitBodyColourHex = ViewPreferences.defaultBodyColourHex;
  double _orbitBodyOpacity = 0.75;

  /// Sketcher restructure Phase 2 follow-up (P8/P9): on-device feedback -
  /// now that real Bodies are visible behind the embedded sketch plane
  /// (previously an unfixable mismatch, see the doc comment above), the
  /// sketch plane's own translucent surface finally has something worth
  /// seeing through it, and grid lines give the plane visual structure now
  /// there's no flat canvas underneath it. Session-only, same convention as
  /// [_orbitRenderMode]/[_orbitBodyColourHex]/[_orbitBodyOpacity] just above.
  /// [_orbitGridVisible] defaults **on**, per the explicit ask.
  String _orbitCanvasColourHex = '#F2F2F2';
  double _orbitCanvasOpacity = 0.18;
  bool _orbitGridVisible = true;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? SketchController();
    final adoptSketchId = widget.adoptSketchId;
    if (adoptSketchId != null) {
      _controller.adoptSketch(
        adoptSketchId,
        partId: widget.documentPartId,
        sketchFeatureId: widget.sketchFeatureId,
      );
    } else {
      _controller.ensureSketch();
    }
    _loadInitialOrbitViewPreference();
  }

  /// Sketcher restructure Phase 2's rollout default: [SketcherPreferences]
  /// decides whether a newly opened Sketch starts in Orbit View (the
  /// 3D-embedded sketcher) or the flat 2D canvas - the live toggle FAB
  /// still works regardless once loaded. Starts `false` (2D) until this
  /// resolves, same one-frame-behind tradeoff `MeshViewerSettingsScreen`
  /// accepts for the same `shared_preferences` load.
  Future<void> _loadInitialOrbitViewPreference() async {
    // On-device feedback: the embedded Orbit View's background used to
    // always fall back to [ViewPreferences.defaultBgColourHex] regardless
    // of what the user already set for the main 3D viewport - loaded here
    // (defensively, alongside [SketcherPreferences] - a bare, Part-less
    // Sketch may never go through [PartScreen]'s own load) so
    // [ViewPreferences.bgColourHex] reflects the real persisted value by
    // the time [_buildBaseLayer] first reads it.
    await Future.wait([SketcherPreferences.load(), ViewPreferences.load()]);
    if (!mounted || _orbitViewActive || widget.standalone) return;
    if (SketcherPreferences.use3DSketcher && _effectiveOrbitBasis != null) {
      _enterOrbitView();
    } else if (SketcherPreferences.use3DSketcher) {
      // Plane basis hasn't resolved yet (adoptSketch/ensureSketch is still
      // in flight) - retry once the controller notifies.
      _controller.addListener(_enterOrbitViewOncePlaneReadyIfPreferred);
    }
  }

  void _enterOrbitViewOncePlaneReadyIfPreferred() {
    if (!mounted || _orbitViewActive || _effectiveOrbitBasis == null) return;
    _controller.removeListener(_enterOrbitViewOncePlaneReadyIfPreferred);
    _enterOrbitView();
  }

  @override
  void dispose() {
    _controller.removeListener(_enterOrbitViewOncePlaneReadyIfPreferred);
    // Only dispose a controller this widget created itself - an injected
    // (e.g. test-owned, or PartScreen-owned) controller's lifecycle belongs
    // to its caller.
    if (widget.controller == null) {
      _controller.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        leading: const DidsaLogoButton(),
        leadingWidth: 100,
        centerTitle: false,
        title: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            // The constraint-state indicator - icon only, no label (moved
            // out of the canvas overlay, where it used to sit behind the
            // Exit Sketch FAB). Shown whenever there's actually some drawn
            // geometry to have a constraint state at all (see
            // SketchController.hasGeometry's doc comment for why that check
            // matters) - open padlock while under-constrained, closed once
            // the most recent solve reports dof == 0. Bug-fix: this used to
            // hide entirely while under-constrained, which left no way to
            // tell "under-constrained" apart from "the indicator hasn't
            // caught up yet" purely by looking at the title bar.
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                if (!_controller.hasGeometry) return const SizedBox.shrink();
                final underConstrained = _controller.isUnderConstrained;
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: SvgPicture.asset(
                    underConstrained
                        ? 'assets/icons/sketchbar/sketchbar_lock_partial.svg'
                        : 'assets/icons/sketchbar/sketchbar_lock_full.svg',
                    key: ValueKey(underConstrained ? 'lock-indicator-partial' : 'lock-indicator-full'),
                    width: 24,
                    height: 24,
                    colorFilter: ColorFilter.mode(
                      Theme.of(context).colorScheme.onSurface,
                      BlendMode.srcIn,
                    ),
                  ),
                );
              },
            ),
            // Bug-fix: plain Text in a mainAxisSize.min Row has no way to
            // shrink, so on a narrow/large-text-scale device it could push
            // the whole title past the AppBar's available width and trip a
            // RenderFlex overflow. Flexible+ellipsis lets it shrink instead.
            const Flexible(
              child: Text(
                'DIDSA-CAD Sketch',
                textAlign: TextAlign.right,
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
        actions: [
          // Stage 19b item 4: always visible, disabled once the undo stack
          // is empty.
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => IconButton(
              icon: SvgPicture.asset(
                'assets/icons/sketchbar/sketchbar_undo.svg',
                width: 30,
                height: 30,
                colorFilter: ColorFilter.mode(
                  _controller.canUndo
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context).disabledColor,
                  BlendMode.srcIn,
                ),
              ),
              tooltip: 'Undo',
              onPressed: _controller.canUndo ? _controller.undo : null,
            ),
          ),
          // Stage 19b item 5: only shown in select mode - greyed out/hidden
          // in draw mode, where there's nothing to multi-select onto.
          AnimatedBuilder(
            animation: _controller,
            builder: (context, _) {
              if (_controller.mode != SketchMode.select) return const SizedBox.shrink();
              return IconButton(
                icon: SvgPicture.asset(
                  'assets/icons/sketchbar/sketchbar_select_all.svg',
                  width: 30,
                  height: 30,
                  colorFilter: ColorFilter.mode(
                    Theme.of(context).colorScheme.onSurface,
                    BlendMode.srcIn,
                  ),
                ),
                tooltip: 'Select all',
                onPressed: _controller.selectAll,
              );
            },
          ),
        ],
      ),
      body: SafeArea(
        child: Column(
          children: [
            AnimatedBuilder(
              animation: _controller,
              builder: (context, _) {
                if (_controller.errorMessage == null) return const SizedBox.shrink();
                return Container(
                  width: double.infinity,
                  color: Colors.red.shade100,
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  child: Text(
                    _controller.errorMessage!,
                    style: TextStyle(color: Colors.red.shade900),
                  ),
                );
              },
            ),
            Expanded(
              child: Stack(
                children: [
                  // On-device feedback: this used to be called directly
                  // (unwrapped) here, so it only ever reflected
                  // _controller's state as of this Stack's *last* rebuild -
                  // in particular, _controller.plane is still null on the
                  // very first synchronous build (ensureSketch/adoptSketch
                  // resolves asynchronously), so the body backdrop's
                  // showBodyBackdrop check always failed on first load and
                  // nothing here re-evaluated it once plane actually
                  // resolved, unless something else (e.g. toggling Orbit
                  // View) happened to force a whole-screen rebuild first -
                  // exactly the reported "wasn't visible until I entered
                  // the 3D view mode" bug.
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) => _buildBaseLayer(),
                  ),
                  // Top-right: Exit Sketch (most prominent/most reached-for
                  // action) plus the optional reference-body visibility
                  // toggle.
                  Positioned(
                    top: 8,
                    right: 8,
                    child: SafeArea(
                      bottom: false,
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.end,
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          FloatingActionButton.small(
                            heroTag: 'exit-sketch-fab',
                            tooltip: 'Exit Sketch',
                            onPressed: () => Navigator.of(context).pop(),
                            child: SvgPicture.asset(
                              'assets/icons/sketchbar/sketchbar_exit.svg',
                              width: 30,
                              height: 30,
                              colorFilter: ColorFilter.mode(
                                Theme.of(context).colorScheme.onPrimaryContainer,
                                BlendMode.srcIn,
                              ),
                            ),
                          ),
                          if (widget.referenceGhostSegments.isNotEmpty || widget.otherSketchGeometries.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'reference-body-visibility-fab',
                              // On-device feedback: this toggle now also
                              // covers [widget.otherSketchGeometries] (see
                              // its own doc comment) - kept the same
                              // tooltip/icon pair rather than a third state,
                              // since "reference body" already reads as
                              // shorthand for "everything else in the model
                              // shown for context" to anyone using it.
                              tooltip:
                                  _referenceBodyHidden ? 'Show Reference Body' : 'Hide Reference Body',
                              onPressed: () => setState(() => _referenceBodyHidden = !_referenceBodyHidden),
                              child: SvgPicture.asset(
                                _referenceBodyHidden
                                    ? 'assets/icons/sketchbar/sketchbar_show_reference_body.svg'
                                    : 'assets/icons/sketchbar/sketchbar_hide_reference_body.svg',
                                width: 30,
                                height: 30,
                                colorFilter: ColorFilter.mode(
                                  Theme.of(context).colorScheme.onPrimaryContainer,
                                  BlendMode.srcIn,
                                ),
                              ),
                            ),
                          ],
                          // P19 on-device feedback: only offered once Orbit
                          // View is actually active - with the FAB's old
                          // enter/exit role gone (see [_orbitCursorActive]'s
                          // own doc comment), there's nothing here to toggle
                          // while still on the flat 2D canvas.
                          if (_orbitViewActive)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: FloatingActionButton.small(
                                heroTag: 'orbit-view-toggle-fab',
                                tooltip: _orbitCursorActive ? 'Switch to Orbit' : 'Switch to Cursor',
                                // P19 on-device feedback: "colours are
                                // reversed, when on looks off" - highlighted
                                // (primary) now means the orbit *icon*
                                // itself is genuinely active (orbit
                                // sub-mode), not cursor sub-mode (the
                                // default, unhighlighted state).
                                backgroundColor: _orbitCursorActive ? null : Theme.of(context).colorScheme.primary,
                                foregroundColor:
                                    _orbitCursorActive ? null : Theme.of(context).colorScheme.onPrimary,
                                onPressed: () => setState(() => _orbitCursorActive = !_orbitCursorActive),
                                child: SvgPicture.asset(
                                  'assets/icons/sketchbar/sketchbar_orbit_view.svg',
                                  width: 30,
                                  height: 30,
                                  colorFilter: ColorFilter.mode(
                                    _orbitCursorActive
                                        ? Theme.of(context).colorScheme.onPrimaryContainer
                                        : Theme.of(context).colorScheme.onPrimary,
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                          // Sketcher restructure Phase 2: moved here from the
                          // bottom-right FAB slot, which now shows the
                          // (restricted) tool speed dial instead of this
                          // button while Orbit View is interactive - see
                          // [_buildBaseLayer]'s own doc comment.
                          if (_orbitViewActive)
                            Padding(
                              padding: const EdgeInsets.only(top: 8),
                              child: FloatingActionButton.small(
                                heroTag: 'orbit-return-to-default-fab',
                                tooltip: 'Return to Default View',
                                onPressed: _returnOrbitToDefaultView,
                                child: SvgPicture.asset(
                                  'assets/icons/sketchbar/sketchbar_reset_view.svg',
                                  width: 30,
                                  height: 30,
                                  colorFilter: ColorFilter.mode(
                                    Theme.of(context).colorScheme.onPrimaryContainer,
                                    BlendMode.srcIn,
                                  ),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ),
                  // Top-left: the menu FAB, matching the 3D viewport screen's
                  // hamburger-fab position exactly (rather than just its
                  // "stacked small FAB" style) - rendered *before* SketchRibbon
                  // below, so the ribbon (the contextual selection drawer)
                  // sits in front of it and covers it whenever the ribbon is
                  // showing over the same top-left corner, rather than the
                  // FAB floating on top of the ribbon's content.
                  Positioned(
                    top: 8,
                    left: 8,
                    child: SafeArea(
                      bottom: false,
                      child: FloatingActionButton.small(
                        heroTag: 'sketch-menu-fab',
                        tooltip: 'Menu',
                        onPressed: () => setState(() => _menuOpen = !_menuOpen),
                        child: SvgPicture.asset(
                          'assets/icons/sketchbar/sketchbar_menu.svg',
                          width: 30,
                          height: 30,
                          colorFilter: ColorFilter.mode(
                            Theme.of(context).colorScheme.onPrimaryContainer,
                            BlendMode.srcIn,
                          ),
                        ),
                      ),
                    ),
                  ),
                  // SketchRibbon aligns and sizes itself (top-left,
                  // shrink-wrapped to its own content) - this just gives it
                  // room to do so without forcing a particular size. Placed
                  // after (in front of) the menu FAB above so the ribbon is
                  // the topmost thing in that corner whenever it's visible.
                  // Sketcher restructure Phase 2 follow-up (P14): no longer
                  // hidden during Orbit View - now that the embedded 3D view
                  // has its own cursor/select mode (P12/P13), the ribbon (a
                  // plain screen-space overlay with no 2D-canvas coordinate
                  // dependency of its own) already works against a
                  // 3D-selected entity unmodified.
                  Positioned.fill(child: SketchRibbon(controller: _controller)),
                  // Tap-outside barrier: while the FAB menu is open, any tap
                  // outside the FAB itself (which sits above this in the
                  // Stack, so remains tappable) closes the menu instead of
                  // reaching the canvas underneath.
                  AnimatedBuilder(
                    animation: _controller,
                    builder: (context, _) {
                      if (_controller.fabMenu == FabMenuState.closed) {
                        return const SizedBox.shrink();
                      }
                      return Positioned.fill(
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onTap: _controller.closeFabMenu,
                          child: const SizedBox.expand(),
                        ),
                      );
                    },
                  ),
                  Positioned(
                    top: 8,
                    left: 0,
                    right: 0,
                    child: Center(
                      child: AnimatedBuilder(
                        animation: _controller,
                        builder: (context, _) {
                          // Sketcher restructure Phase 2 follow-up (P12):
                          // this used to be hidden outright during Orbit
                          // View - now the same pill/tap-to-exitToSelectMode
                          // mechanism doubles as the embedded 3D view's own
                          // "enter cursor mode" toggle.
                          if (_controller.mode == SketchMode.select) {
                            return const SizedBox.shrink();
                          }
                          final pill = Material(
                            color: Colors.black54,
                            borderRadius: BorderRadius.circular(16),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                              child: Text(
                                _controller.modeLabel,
                                style: const TextStyle(color: Colors.white),
                              ),
                            ),
                          );
                          return GestureDetector(
                            onTap: _controller.exitToSelectMode,
                            child: pill,
                          );
                        },
                      ),
                    ),
                  ),
                  // Bottom-right: the draw/dimension tool speed dial -
                  // sketcher restructure Phase 2: shown in Orbit View too
                  // now that it's genuinely interactive; P20: every tool
                  // except Text now works there (see [SketchSpeedDial.
                  // restrictToEmbeddedTools]). The "Return to Default View"
                  // button that used to occupy this slot while look-only
                  // moved to the top-right FAB column, next to the
                  // orbit/cursor toggle.
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: SketchSpeedDial(controller: _controller, restrictToEmbeddedTools: _orbitViewActive),
                  ),
                  // Drag-mode toggle FAB, bottom-left: replaces the old
                  // timing-based "double-tap/double-click to drag" gesture
                  // (too many false positives - a plain select-tap followed
                  // by an ordinary drag-intent tap was easily misread as the
                  // second half of a double-click). While toggled on, the
                  // canvas grabs whatever's under the cursor on the very
                  // next pointer-down instead of waiting for a second tap.
                  // Select-mode only, same gating as the "select all"
                  // button above - there's nothing draggable in draw/
                  // dimension mode.
                  //
                  // Bug-fix: bottom:16 used to sit directly on top of
                  // PlaneIndicator (SketchCanvas's own bottom-left plane/axis
                  // triad, also anchored bottom:8/left:8 - see
                  // sketch_canvas.dart's Positioned around its own Stack) -
                  // raised well above the triad's ~40px footprint to clear it.
                  Positioned(
                    left: 16,
                    bottom: 72,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        // P24 (2D-sketcher feature parity): reachable in
                        // Orbit View too now, but only in cursor sub-mode -
                        // orbit sub-mode has no cursor to grab with (see
                        // [_orbitCursorActive]'s own doc comment).
                        if (_controller.mode != SketchMode.select ||
                            (_orbitViewActive && !_orbitCursorActive)) {
                          return const SizedBox.shrink();
                        }
                        final active = _controller.dragModeEnabled;
                        final theme = Theme.of(context);
                        return FloatingActionButton.small(
                          heroTag: 'drag-mode-fab',
                          tooltip: active ? 'Drag mode on - tap to turn off' : 'Drag mode off - tap to drag entities',
                          backgroundColor: active ? theme.colorScheme.primary : null,
                          foregroundColor: active ? theme.colorScheme.onPrimary : null,
                          onPressed: _controller.toggleDragMode,
                          child: SvgPicture.asset(
                            'assets/icons/sketchbar/sketchbar_drag_mode.svg',
                            width: 30,
                            height: 30,
                            colorFilter: ColorFilter.mode(
                              active ? theme.colorScheme.onPrimary : theme.colorScheme.onPrimaryContainer,
                              BlendMode.srcIn,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Construction-method/dimension picker: flies up from the
                  // bottom whenever draw or dimension mode is active,
                  // non-modal so taps still reach the canvas underneath (see
                  // SketchConstructionMethodBar's own doc comment for why).
                  Positioned(
                    left: 0,
                    right: 0,
                    bottom: 0,
                    child: AnimatedBuilder(
                      animation: _controller,
                      builder: (context, _) {
                        final mode = _controller.mode;
                        // Every draw tool gets this fly-up bar (with its Exit
                        // button) while active - SketchTool.point has no
                        // construction-method choice, so
                        // SketchConstructionMethodBar shows a plain
                        // "Tap to place a point" message instead of chips,
                        // but the bar (and its Exit button) still appears.
                        //
                        // P26 (on-device feedback: "missing option to change
                        // number of sides of polygon", "missing finish
                        // button on tools"): now shown in Orbit View too -
                        // Polygon's side-count stepper/guide-circle toggle
                        // and every tool's own Exit button live only in this
                        // bar, and P20 already opened every one of these
                        // tools up to Orbit View without bringing this along.
                        // P38: Dimension mode's own bar shown in Orbit View
                        // too now - SketchDimensionBar has no ViewTransform/
                        // 2D-canvas dependency of its own (a plain
                        // screen-space overlay, same as SketchRibbon already
                        // is), so nothing here needed to change beyond
                        // dropping this gate.
                        //
                        // On-device feedback round 2: OffsetValueBar only
                        // once picking is actually done (offsetPreviewTargets
                        // non-null) - the picking phase itself relies on the
                        // hover highlight and the Tools flyup's own Finish
                        // button, not this bar.
                        final showConstructionBar = mode == SketchMode.draw;
                        final showDimensionBar = mode == SketchMode.dimension;
                        final showOffsetBar =
                            mode == SketchMode.offset && _controller.offsetPreviewTargets != null;
                        final visible = showConstructionBar || showDimensionBar || showOffsetBar;
                        final bar = switch (mode) {
                          SketchMode.dimension => SketchDimensionBar(controller: _controller),
                          SketchMode.offset => OffsetValueBar(controller: _controller),
                          _ => SketchConstructionMethodBar(controller: _controller),
                        };
                        return IgnorePointer(
                          ignoring: !visible,
                          child: AnimatedSlide(
                            duration: const Duration(milliseconds: 200),
                            curve: Curves.easeOut,
                            offset: visible ? Offset.zero : const Offset(0, 1),
                            child: AnimatedOpacity(
                              duration: const Duration(milliseconds: 200),
                              opacity: visible ? 1 : 0,
                              child: bar,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  // Hamburger menu overlay - a scrim (tap to close) plus a
                  // bounded panel, anchored top-left below the AppBar/menu
                  // FAB. Deliberately *not* Scaffold's built-in [Drawer]:
                  // that widget is always full-screen height by
                  // construction (no `height`/bounding parameter exists),
                  // so a previous fix that only padded its *content* down
                  // still left the panel's own Material surface spanning
                  // the whole screen. Living inside this body Stack (which
                  // Scaffold already positions strictly below the AppBar)
                  // means the top can never cover the title bar/DIDSA logo
                  // without any padding hack, and the height cap below
                  // keeps the bottom well short of full-screen (around
                  // mid-screen at most, hugging its actually-short content
                  // in practice).
                  if (_menuOpen)
                    Positioned.fill(
                      child: Stack(
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: () => setState(() => _menuOpen = false),
                              child: Container(color: Colors.black45),
                            ),
                          ),
                          Positioned(
                            top: 56,
                            left: 8,
                            child: ConstrainedBox(
                              constraints: BoxConstraints(
                                maxWidth: 220,
                                maxHeight: MediaQuery.of(context).size.height * 0.5,
                              ),
                              child: Material(
                                elevation: 8,
                                borderRadius: BorderRadius.circular(8),
                                clipBehavior: Clip.antiAlias,
                                child: _buildMenuPanel(context),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// The Sketch plane this screen is editing, resolved to one of the three
  /// fixed [ReferencePlaneKind]s - null before `ensureSketch`/`adoptSketch`
  /// resolves, or for a custom-plane Sketch (no `orientationFacingPlane`
  /// equivalent yet for those).
  ReferencePlaneKind? get _planeKind => referencePlaneKindFromApiValue(_controller.plane);

  /// On-device feedback (bug fix): the basis Orbit View actually renders/
  /// animates against - prefers [SketchScreen.planeBasis] (correct for both
  /// a fixed and a custom plane), falling back to reconstructing a fixed
  /// plane's own oriented basis from [_planeKind] when it's null (isolated
  /// tests, or [PartScreen] couldn't resolve one) - null only when neither
  /// resolves, same "nothing to orbit toward" case [_planeKind] alone used
  /// to be the sole gate for.
  SketchPlaneBasis? get _effectiveOrbitBasis {
    final basis = widget.planeBasis;
    if (basis != null) return basis;
    final planeKind = _planeKind;
    if (planeKind == null) return null;
    return SketchPlaneBasis.oriented(
      planeKind,
      flip: _controller.flip,
      rotationQuarterTurns: _controller.rotationQuarterTurns,
    );
  }

  /// Phase 4.1/4.2, on-device feedback round: the Stack's base layer.
  ///
  /// While [_orbitViewActive]: a 3D [PartViewport] embedding [widget.bodies]
  /// (shaded, at [_orbitBodyOpacity]) alongside this Sketch's own geometry,
  /// reusing `viewport3d/sketch_geometry_3d.dart`'s existing projection -
  /// "so the user can see where they are sketching" relative to the real
  /// part, per the brief. Sketcher restructure Phase 2: genuinely
  /// interactive as of this phase (was read-only/look-only before - see
  /// git history for that era's doc comment); P16-P18 retrofitted drawing
  /// itself onto a cursor+ghost+commit model ([_orbitCursorActive]'s own
  /// doc comment), and P20 opened that model up to every draw tool except
  /// Text (see [SketchSpeedDial.restrictToEmbeddedTools]) - a genuine tap
  /// (not a cursor drag) commits via [_handleEmbeddedSketchTap]/
  /// [_handleDrawCursorMoved] either way. Select mode ([selectionMode]) is
  /// also supported here, gated the same way.
  ///
  /// Otherwise: just the flat 2D [SketchCanvas] - no 3D body backdrop.
  /// On-device feedback: a body backdrop behind the flat canvas used to be
  /// shown here too, synced to the 2D canvas's own pan/zoom, but its camera
  /// was necessarily perspective (`flutter_scene` has no orthographic
  /// camera - `OrbitCamera.cameraFor` always returns a `PerspectiveCamera`,
  /// the `isPerspective` flag is a no-op) while the 2D canvas it sat behind
  /// is an inherently flat/orthographic projection - anything off the one
  /// depth plane the sync matched necessarily showed real perspective
  /// foreshortening the canvas couldn't, an unfixable mismatch rather than
  /// a bug to chase further. Removed outright rather than patched: the
  /// Sketch's own drawn geometry already shades its enclosed area via
  /// [SketchController.closedProfileFills] (unconditional, unrelated to
  /// this backdrop), and the real Body geometry stays reachable via Orbit
  /// View above, which was never affected by this mismatch (its own camera
  /// and the geometry it's comparing against are both genuinely 3D).
  Widget _buildBaseLayer() {
    final orbitBasis = _effectiveOrbitBasis;
    if (_orbitViewActive && orbitBasis != null) {
      return PartViewport(
        key: _orbitViewportKey,
        bodies: widget.bodies,
        // On-device feedback ("Show reference body button in the sketcher
        // should now toggle visibility of all bodies on/off"): the same
        // toggle that used to only gate the 2D canvas's own projected
        // ghost overlay now also suppresses the real 3D body meshes.
        bodiesHidden: _referenceBodyHidden,
        selectedPlane: null,
        onPlaneTap: (_) {},
        onBackgroundTap: () {},
        sketchPlaneBasis: orbitBasis,
        onSketchPlaneTap: _handleEmbeddedSketchTap,
        // P18/P20: "sketching should always be done with the cursor, not
        // with taps" - covers every draw tool reachable while this
        // landing's SketchMode.draw is active (see [SketchSpeedDial.
        // restrictToEmbeddedTools] - everything except Text). Select stays
        // on the plain-tap `_handleTap`/`onSketchEntityTap` path in
        // `PartViewport` (not reached at all while `drawCursorMode` is
        // true), unaffected. Also gated on _orbitCursorActive (P19
        // on-device feedback: the orbit-view-toggle FAB now swaps between
        // this cursor model and plain camera orbiting with immediate
        // tap-to-place - see that field's own doc comment) - false reverts
        // a tap straight to the plain-tap path, exactly the pre-P16
        // behaviour.
        // P24: also covers drag mode ([_dragModeActiveInOrbitView]) -
        // dragging needs this same plane-raycast cursor, not Selection
        // mode's mesh-hover one (see that field's own doc comment). P30:
        // also covers Trim/Extend - [_handleEmbeddedDrawOrDragCommit]
        // already falls through to [_handleEmbeddedSketchTap] (->
        // handleCanvasTap -> the controller's own mode dispatch,
        // including _handleTrimTap) for any mode that isn't drag, so
        // widening this gate is the only plumbing Trim/Extend needs to get
        // the same "aim precisely, then tap to commit" cursor model every
        // other mode already has. P38 added Dimension mode to this same
        // gate for the same reason - but on-device feedback later showed
        // this comment's own claim above ("Dimension... stay on the
        // plain-tap... path") was **wrong**: once Dimension moved onto
        // *this* cursor-commit path, real-Body vertex/edge picking
        // (`PartViewport.preferEntityPick`/`onSketchEntityTap`, P10) - which
        // only `_handleTap` ever consulted - silently stopped firing for
        // every Dimension-mode tap, since `_handleTap` itself is
        // unreachable whenever `drawCursorMode` is true (see
        // `_onPointerEnd`). Fixed at the root - `PartViewport.
        // _commitDrawCursor` now also consults `preferEntityPick`/
        // `hitTestBodies`/`onSketchEntityTap` before falling back to its
        // own plane-point commit - not by excluding Dimension mode from
        // this gate again. Convert Entities/Offset (added since, same
        // reasoning as Trim/Extend - `_handleOffsetTap`/`pickConvertEntity*`
        // dispatch the same generic way) get this fix for free too, since
        // they share the exact same `preferEntityPick` mechanism.
        drawCursorMode: _orbitCursorActive &&
            (_controller.mode == SketchMode.draw ||
                _controller.mode == SketchMode.trim ||
                _controller.mode == SketchMode.dimension ||
                _controller.mode == SketchMode.convert ||
                _controller.mode == SketchMode.offset ||
                _dragModeActiveInOrbitView),
        onDrawCursorMoved: _handleDrawCursorMoved,
        onDrawCursorCommit: _handleEmbeddedDrawOrDragCommit,
        // P30: mirrors sketch_canvas.dart's own cursor colour convention
        // (green only for SketchMode.draw, red for everything else it
        // ever tints - select and, now, trim) - drawCursorMode's own gate
        // just above no longer implies "actively drawing" by itself.
        drawCursorHoverColor:
            _controller.mode == SketchMode.draw || _dragModeActiveInOrbitView ? const Color(0xFF4CAF50) : Colors.red,
        // On-device feedback ("when I grab something to perform a drag,
        // the cursor should disappear... it should feel like I'm now
        // moving the entity around"): see PartViewport.suppressDrawCursor's
        // own doc comment.
        suppressDrawCursor: _dragModeActiveInOrbitView && _controller.isEntityGrabbed,
        drawGhostPolylines: _embeddedDrawGhostPolylines,
        drawGhostColor: _embeddedDrawGhostColor,
        drawGhostGuidePolylines: _embeddedDrawGhostGuidePolylines,
        drawIndicatorMarkers: _embeddedDrawIndicatorMarkers,
        profileFillOutlines: _embeddedProfileFillOutlines,
        profileBranchMarkers: _embeddedProfileBranchMarkers,
        constraintOverlayItems: _embeddedConstraintOverlayItems,
        preferConstraintOverlayHitOnCommit:
            _controller.mode == SketchMode.dimension || _dragModeActiveInOrbitView,
        onConstraintOverlayItemTap: _handleEmbeddedConstraintOverlayTap,
        isDraggingConstraintLabel: _controller.draggingLabelId != null,
        onConstraintLabelDragDelta: _controller.updateLabelDrag,
        draggingConstraintLabelId: _controller.draggingLabelId,
        onRadialLabelAngleDragged: _handleEmbeddedRadialLabelAngleDragged,
        onLinearLabelOffsetDragged: _handleEmbeddedLinearLabelOffsetDragged,
        activeConstraintOverlayItemId: _controller.activeGhostKey,
        activeConstraintOverlayItemBuilder: _buildActiveGhostValueEditor,
        sketchGeometries: _embeddedSketchGeometries,
        sketchEntityColors: _embeddedSketchEntityColors,
        referencePlanesHidden: true,
        renderMode: _orbitRenderMode,
        bodyColourHex: _orbitBodyColourHex,
        bodyOpacity: _orbitBodyOpacity,
        bgColourHex: ViewPreferences.bgColourHex,
        sketchPlaneSurfaceColourHex: _orbitCanvasColourHex,
        sketchPlaneSurfaceOpacity: _orbitCanvasOpacity,
        sketchPlaneGridVisible: _orbitGridVisible,
        preferEntityPick: _preferEntityPickOnTap,
        // On-device feedback ("selecting a face brings in all the face
        // edges as lines"): only Convert Entities ever wants a Face hit -
        // see PartViewport.preferEntityPickIncludesFace's own doc comment.
        preferEntityPickIncludesFace: _controller.mode == SketchMode.convert,
        onSketchEntityTap: _handleEmbeddedSketchEntityTap,
        hasEntityNearSketchTap: (x, y) => _controller.hasEntityNear(x, y, SketchController.snapRadius),
        // P19 on-device feedback: same _orbitCursorActive gating as
        // drawCursorMode above - orbit sub-mode reverts selection to plain
        // camera orbiting with no live hover/cursor either. P24: excludes
        // drag mode too - see [_dragModeActiveInOrbitView]'s own doc
        // comment for why that needs drawCursorMode's plane cursor instead.
        selectionMode: _orbitCursorActive && _controller.mode == SketchMode.select && !_dragModeActiveInOrbitView,
        selectionFilter: _embeddedCursorModeFilter,
        selectedEntities: _embeddedSelectedEntities,
        onSelectionToggle: _handleEmbeddedSelectionToggle,
        onClearSelection: _controller.closeRibbon,
        // P25 (2D-sketcher feature parity): feeds straight into
        // SketchController.selectInRect - the exact same method
        // sketch_canvas.dart's own marquee already uses.
        onMarqueeSelect: _controller.selectInRect,
        initialViewBasis: orbitBasis,
      );
    }
    return SketchCanvas(
      controller: _controller,
      referenceGhostSegments: widget.referenceGhostSegments,
      referenceGhostVertices: widget.referenceGhostVertices,
      referenceGhostEdges: widget.referenceGhostEdges,
      referenceBodyHidden: _referenceBodyHidden,
      constraintLabelsVisible: _constraintLabelsVisible,
      canvasColor: _canvasColor,
    );
  }

  /// P10: whether a tap in the embedded 3D view should prefer picking a
  /// real Body vertex/edge over placing new geometry on the plane - starts
  /// with Dimension mode, which already supports referencing real Body
  /// geometry on the flat 2D canvas (via ghost-pick - see
  /// [SketchController.pickReferenceGhostVertex]/[pickReferenceGhostEdge]'s
  /// own doc comments). P48/P50 (Sketcher-roadmap Phase 9 v1/v2): Convert
  /// Entities is exactly the "later mode" this getter's own doc comment
  /// anticipated - the one-line addition it predicted. On-device feedback
  /// (P52): Offset mode too - "select edges from other bodies to create
  /// sketch geometry offset from the body edges".
  bool get _preferEntityPickOnTap =>
      _controller.mode == SketchMode.dimension ||
      _controller.mode == SketchMode.convert ||
      _controller.mode == SketchMode.offset;

  /// P10: [PartViewport.onSketchEntityTap]'s handler - materializes a real
  /// Body vertex/edge as either a dimensionable Point/Line ([SketchMode.
  /// dimension], via the exact same [SketchController] methods the flat 2D
  /// canvas's own ghost-pick already uses) or a real, non-construction
  /// Point/Line ([SketchMode.convert], P48) - once materialized, a picked
  /// Body entity is indistinguishable from any other Point/Line, so every
  /// existing ghost-building/confirm/undo (dimension) or delete/edit
  /// (convert) path already works against it unmodified - see those
  /// methods' own doc comments for the full picture.
  ///
  /// On-device feedback (P52): [SketchMode.offset]'s own Body-edge pick -
  /// converts the edge (same mechanism as Convert Entities) then
  /// immediately offers the result up for offsetting via
  /// [SketchController.offsetPreviewTargets], rather than requiring two
  /// separate tool sessions. A Face hit only ever means anything in
  /// Convert Entities ("selecting a face brings in all the face edges as
  /// lines") - converts every one of the face's own boundary edges in one
  /// tap, reusing [_toggleFilletFaceEdges]'s own `faceEdgeIds` resolution
  /// pattern from `part_screen.dart`.
  void _handleEmbeddedSketchEntityTap(SelectionEntityRef entity) {
    final convert = _controller.mode == SketchMode.convert;
    final offset = _controller.mode == SketchMode.offset;
    switch (entity.kind) {
      case SelectionEntityKind.vertex:
        unawaited(
          convert
              ? _controller.pickConvertEntityVertex(entity.bodyId, entity.id)
              : _controller.pickReferenceGhostVertex(entity.bodyId, entity.id),
        );
      case SelectionEntityKind.edge:
        if (offset) {
          unawaited(_controller.pickBodyEdgeForOffset(entity.bodyId, entity.id));
          return;
        }
        unawaited(
          convert
              ? _controller.pickConvertEntityEdge(entity.bodyId, entity.id)
              : _controller.pickReferenceGhostEdge(entity.bodyId, entity.id),
        );
      case SelectionEntityKind.face:
        if (convert) unawaited(_convertFaceEdges(entity));
      default:
        break;
    }
  }

  /// On-device feedback ("selecting a face brings in all the face edges as
  /// lines"): resolves [faceEntity]'s own boundary edge loop from the
  /// already-fetched mesh data (same `BodyMeshDto.mesh.faceEdgeIds`
  /// `part_screen.dart`'s `_toggleFilletFaceEdges` already resolves against
  /// - a stale hit against mesh data that's since changed, or a face
  /// bordering no edges at all, is a silent no-op, same as that method),
  /// then converts each edge in turn. Sequential (not `Future.wait`), not
  /// just for a stable insertion order: two adjacent edges around the
  /// loop share a Body vertex, and `Sketch.add_or_reuse_external_vertex_
  /// reference`'s own reuse only works correctly if the first edge's own
  /// convert call has actually completed (and so materialized that shared
  /// vertex) before the second one's request goes out - firing them
  /// concurrently would race and likely mint two separate Points for the
  /// same corner instead of one shared one.
  Future<void> _convertFaceEdges(SelectionEntityRef faceEntity) async {
    BodyMeshDto? body;
    for (final candidate in widget.bodies) {
      if (candidate.bodyId == faceEntity.bodyId) {
        body = candidate;
        break;
      }
    }
    final faceEdgeIds = body?.mesh.faceEdgeIds;
    if (faceEdgeIds == null || faceEntity.id < 0 || faceEntity.id >= faceEdgeIds.length) return;
    for (final edgeId in faceEdgeIds[faceEntity.id]) {
      await _controller.pickConvertEntityEdge(faceEntity.bodyId, edgeId);
    }
  }

  /// P12/P33: every real Sketch-entity kind is selectable in this cursor
  /// mode (Point/Line/Circle/Arc/Ellipse/Spline). Body vertex/edge/face
  /// picking used to be permanently off here - this getter's own doc
  /// comment used to claim that was fine because "P10's own
  /// `preferEntityPick` already owns [it] for Dimension mode specifically"
  /// - true for the *tap* path (`_handleTap`/`_commitDrawCursor` build
  /// their own bespoke [SelectionFilterState] locally, keyed off
  /// [_preferEntityPickOnTap]/[preferEntityPickIncludesFace], never off
  /// this field), but this field alone drives [PartViewport]'s *hover*
  /// highlight (`_recomputeHover`'s own `filter: widget.selectionFilter`) -
  /// so a permanently-off body vertex/edge/face here meant Dimension/
  /// Convert Entities/Offset could always be *tapped* against real Body
  /// geometry, but never showed any hover feedback first (on-device
  /// feedback: "when in selecting edges, vertices, faces to convert or
  /// offset, there should be dynamic highlight so the user knows what
  /// will need selected"). Now mirrors the tap path's own logic exactly,
  /// so whatever's tappable is also the thing that lights up first.
  SelectionFilterState get _embeddedCursorModeFilter {
    final targetsBodyGeometry = _preferEntityPickOnTap;
    return SelectionFilterState(
      vertex: targetsBodyGeometry,
      edge: targetsBodyGeometry,
      face: _controller.mode == SketchMode.convert,
      body: false,
      sketchPoint: true,
      sketchLine: true,
      sketchCircle: true,
      sketchArc: true,
      sketchEllipse: true,
      sketchSpline: true,
      plane: false,
    );
  }

  /// P13: [PartViewport.onSelectionToggle]'s handler - converts the
  /// resolved [SelectionEntityRef] (3D ray-hit vocabulary) into the matching
  /// [SketchSelection] (2D/[SketchController] vocabulary) and applies it via
  /// [SketchController.selectEntity] - the exact same add-to-selection-vs-
  /// replace rule [selectConstraint] already uses, so every existing ribbon
  /// action (Delete, constraints, Length, ...) already works against a
  /// 3D-selected entity unmodified.
  void _handleEmbeddedSelectionToggle(SelectionEntityRef entity) {
    final kind = switch (entity.kind) {
      SelectionEntityKind.sketchPoint => SelectionKind.point,
      SelectionEntityKind.sketchLine => SelectionKind.line,
      SelectionEntityKind.sketchCircle => SelectionKind.circle,
      SelectionEntityKind.sketchArc => SelectionKind.arc,
      SelectionEntityKind.sketchEllipse => SelectionKind.ellipse,
      SelectionEntityKind.sketchSpline => SelectionKind.spline,
      _ => null,
    };
    if (kind == null) return;
    _controller.selectEntity(SketchSelection(kind: kind, id: entity.sketchEntityId));
  }

  /// P13: the reverse of [_handleEmbeddedSelectionToggle] - lets the
  /// embedded 3D view's own persistent-selection highlight reflect
  /// [SketchController.selectionSet], the same way `sketchGeometries` above
  /// is already rebuilt from controller state on every build.
  Set<SelectionEntityRef> get _embeddedSelectedEntities {
    final featureId = _controller.sketchId ?? 'active-sketch';
    return {
      for (final selection in _controller.selectionSet)
        if (_embeddedSelectionEntityKind(selection.kind) case final kind?)
          SelectionEntityRef(
            kind: kind,
            sketchFeatureId: featureId,
            sketchEntityId: selection.id,
          ),
    };
  }

  /// P33: [SelectionKind] -> [SelectionEntityKind] for every real Sketch
  /// entity kind the 3D cursor mode can select (see
  /// [_embeddedCursorModeFilter]/[_handleEmbeddedSelectionToggle]'s own
  /// inverse of this mapping) - null for [SelectionKind.constraint]/`.text`,
  /// which have no [SelectionEntityKind] counterpart (a Constraint has no 3D
  /// hit-test of its own yet; Text isn't drawable in Orbit View at all).
  SelectionEntityKind? _embeddedSelectionEntityKind(SelectionKind kind) => switch (kind) {
        SelectionKind.point => SelectionEntityKind.sketchPoint,
        SelectionKind.line => SelectionEntityKind.sketchLine,
        SelectionKind.circle => SelectionEntityKind.sketchCircle,
        SelectionKind.arc => SelectionEntityKind.sketchArc,
        SelectionKind.ellipse => SelectionEntityKind.sketchEllipse,
        SelectionKind.spline => SelectionEntityKind.sketchSpline,
        SelectionKind.constraint || SelectionKind.text => null,
      };

  /// Sketcher restructure Phase 2: [PartViewport.onSketchPlaneTap]'s
  /// handler - converts the resolved world-space hit point back to this
  /// Sketch's own local (x, y) via the same [worldPointToSketch] every
  /// other 3D-sketch-geometry consumer already uses, then feeds it straight
  /// into [SketchController.handleCanvasTap] - the exact same entry point
  /// every 2D-canvas tap already funnels through (`sketch_canvas.dart`'s
  /// own `_dispatchTap`), so every tool's own tap-handling logic (chain
  /// state, construction-method dispatch, ...) is reused completely
  /// unchanged. Not awaited here (matches `_dispatchTap`'s own
  /// fire-and-forget convention) - [SketchController] is a [ChangeNotifier]
  /// and drives its own UI updates once the call resolves.
  void _handleEmbeddedSketchTap(vm.Vector3 worldPoint) {
    final basis = _effectiveOrbitBasis;
    if (basis == null) return;
    final (x, y) = worldPointToSketch(basis, worldPoint);
    unawaited(_controller.handleCanvasTap(x, y));
  }

  /// P24 (2D-sketcher feature parity): true while Select mode's drag-mode
  /// toggle is on. [_handleDrawCursorMoved]/[_handleEmbeddedDrawOrDragCommit]
  /// branch on this to repurpose the plane-raycast cursor P16-P18 built for
  /// drawing as the 3D-embedded counterpart of `sketch_canvas.dart`'s own
  /// tap-to-grab/tap-to-drop drag gesture, instead of placing new geometry -
  /// dragging fundamentally needs "where on the sketch plane is the
  /// cursor", exactly what that mechanism already resolves, so this reuses
  /// it rather than building a second parallel cursor system. Also flips
  /// [_buildBaseLayer]'s own `selectionMode`/`drawCursorMode` gating so the
  /// two never both apply at once - drag mode needs the plane cursor, not
  /// Selection mode's mesh-hover one.
  bool get _dragModeActiveInOrbitView => _controller.mode == SketchMode.select && _controller.dragModeEnabled;

  /// P18: [PartViewport.onDrawCursorMoved]'s handler - the "always sketching
  /// should be done with the cursor" retrofit's move-side counterpart to
  /// [_handleEmbeddedSketchTap]'s commit-side one. Converts the resolved
  /// world-space hit point back to sketch-local (x, y) the same way, but
  /// feeds [SketchController.moveCursorToSketchPoint] (no tap dispatch)
  /// instead of [SketchController.handleCanvasTap] - this fires on every
  /// cursor move, not just on a genuine tap, so [_controller.activeDrawGhost]
  /// (read by [_embeddedDrawGhostPolylines] below) stays live while aiming.
  ///
  /// P24: while [_dragModeActiveInOrbitView], feeds
  /// [SketchController.updateGrabbedPosition] instead - a no-op unless
  /// something is actually grabbed (mirrors that method's own doc comment).
  void _handleDrawCursorMoved(vm.Vector3 worldPoint) {
    final basis = _effectiveOrbitBasis;
    if (basis == null) return;
    final (x, y) = worldPointToSketch(basis, worldPoint);
    if (_dragModeActiveInOrbitView) {
      if (_controller.isEntityGrabbed) {
        unawaited(_controller.updateGrabbedPosition(x, y));
      }
      return;
    }
    _controller.moveCursorToSketchPoint(x, y);
  }

  /// P24: [PartViewport.onDrawCursorCommit]'s handler while
  /// [_dragModeActiveInOrbitView] - mirrors `sketch_canvas.dart`'s own
  /// `_handleDragModeTap` exactly (drop if already grabbed, otherwise try to
  /// grab whatever [SketchController.dragGrabTargetAt] resolves to at the
  /// tap), falling through to the ordinary [_handleEmbeddedSketchTap] commit
  /// (place-geometry/select-toggle) whenever drag mode isn't active - the
  /// same "drag-mode branch checked first, ordinary tap handling otherwise"
  /// priority `_handleDragModeTap`'s own doc comment describes.
  void _handleEmbeddedDrawOrDragCommit(vm.Vector3 worldPoint) {
    if (!_dragModeActiveInOrbitView) {
      _handleEmbeddedSketchTap(worldPoint);
      return;
    }
    final basis = _effectiveOrbitBasis;
    if (basis == null) return;
    if (_controller.isEntityGrabbed) {
      unawaited(_controller.dropGrabbedEntity());
      return;
    }
    final (x, y) = worldPointToSketch(basis, worldPoint);
    final target = _controller.dragGrabTargetAt(x, y, SketchController.snapRadius);
    if (target == null) return;
    switch (target.kind) {
      case SelectionKind.point:
        _controller.beginPointDrag(target.id);
      case SelectionKind.line:
        _controller.beginLineDrag(target.id);
      default:
        break;
    }
  }

  /// P41 (on-device feedback: "I can't grab them or pick a ghost
  /// dimension"): [PartViewport.onConstraintOverlayItemTap]'s handler -
  /// mirrors `sketch_canvas.dart`'s own `_dispatchTap` (Dimension-mode
  /// ghost-tap branch) and `_handleDragModeTap` (constraint-label-drag
  /// branch) exactly, just re-derived from a resolved hit id instead of
  /// re-walking the geometry itself (already done once, in
  /// [PartViewport]'s own `_commitDrawCursor`, via [constraintOverlayItemAt]).
  ///
  /// [hitId] is deliberately untyped (could be a ghost's own key or a real
  /// Constraint's own id, or neither) - this checks *actual current
  /// membership* in [SketchController.ghosts]/`.constraints` before acting
  /// on it, rather than trusting the caller's context alone, so a tap that
  /// happens to land near an unrelated confirmed dimension while in
  /// Dimension mode (no ghost there) is correctly treated as a miss, not a
  /// wrong-mode action - see [PartViewport.preferConstraintOverlayHitOnCommit]'s
  /// own doc comment for why *whether this fires at all* is still mode-
  /// gated one level up from this.
  bool _handleEmbeddedConstraintOverlayTap(String? hitId) {
    if (_controller.mode == SketchMode.dimension) {
      final isGhost = hitId != null && _controller.ghosts.any((g) => g.key == hitId);
      if (_controller.activeGhostKey != null) {
        // Mirrors _dispatchTap exactly: any tap while an edit is open
        // either confirms staying on the same ghost (no-op, handled by the
        // caller's own value-entry bar) or cancels it - never falls
        // through to placing/picking anything else, matching "tap away to
        // cancel" being unconditional here.
        if (hitId != _controller.activeGhostKey) _controller.cancelGhostEdit();
        return true;
      }
      if (isGhost) {
        _controller.tapGhost(hitId);
        return true;
      }
      return false;
    }
    if (_dragModeActiveInOrbitView) {
      // P43 bug fix (on-device feedback: "drag glyphs/dimensions doesn't
      // work" - a label could be grabbed, but never actually dropped):
      // mirrors `_handleDragModeTap`'s own top-priority check exactly -
      // *something already grabbed* always means "drop it", checked before
      // ever looking at what's under the cursor. Without this, dropping a
      // label by tapping back down near wherever it was just dragged to
      // (the overwhelmingly common case - that's the whole point of a
      // drag) hit this same label again and silently re-grabbed it via
      // [SketchController.beginLabelDrag] instead (that method's own guard
      // only checks a grabbed Point/Line, never an already-grabbed label),
      // so the label could start moving but never stop. Returning false
      // here (not consumed) correctly falls through to
      // [_handleEmbeddedDrawOrDragCommit]'s own existing drag-mode branch,
      // which already drops whatever is grabbed unconditionally.
      if (_controller.isEntityGrabbed) return false;
      if (hitId != null && _controller.constraints.containsKey(hitId)) {
        return _controller.beginLabelDrag(hitId);
      }
      return false;
    }
    // P44e bug fix (on-device feedback: "I can't select a dimension,
    // clicking the dimension does nothing" / "I can't select a constraint
    // by clicking its glyph"): a plain Select-mode tap (not drag mode, not
    // Dimension mode - both already handled above) never checked for a
    // constraint hit at all, so a real, confirmed dimension/glyph could
    // never be selected in Orbit View - only Points/Lines/Circles/etc via
    // the ordinary mesh hit-test. Mirrors `sketch_canvas.dart`'s own
    // `_dispatchTap`, which always checks `_constraintIdAt` first while
    // `mode == SketchMode.select`, ahead of its own ordinary entity pick.
    if (_controller.mode == SketchMode.select &&
        hitId != null &&
        _controller.constraints.containsKey(hitId)) {
      _controller.selectConstraint(hitId);
      return true;
    }
    return false;
  }

  /// P44b: [PartViewport.activeConstraintOverlayItemBuilder] - the embedded
  /// view's own [GhostValueEditor] (the same widget `sketch_canvas.dart`'s
  /// flat 2D view already renders), anchored wherever [PartViewport] itself
  /// resolved the active ghost's current on-screen label position to. Only
  /// ever invoked while [PartViewport.activeConstraintOverlayItemId] is
  /// non-null (see that field's own doc comment), but still defensively
  /// re-checks [SketchController.activeGhostKey]/[SketchController.ghosts]
  /// membership itself - the two widgets rebuild from independent
  /// `AnimatedBuilder`s, so a ghost cancelled/confirmed one frame earlier
  /// could otherwise still be looked up here on a stale frame.
  Widget _buildActiveGhostValueEditor(Offset anchor) {
    final key = _controller.activeGhostKey;
    if (key == null) return const SizedBox.shrink();
    DimensionGhost? ghost;
    for (final candidate in _controller.ghosts) {
      if (candidate.key == key) {
        ghost = candidate;
        break;
      }
    }
    if (ghost == null) return const SizedBox.shrink();
    return GhostValueEditor(key: ValueKey(key), controller: _controller, ghost: ghost, anchor: anchor);
  }

  /// P44f bug fix (on-device feedback: "the arrow should remain at the
  /// same angular position when orbiting"): [PartViewport.
  /// onRadialLabelAngleDragged]'s handler - just forwards the resolved
  /// angle straight to [SketchController.setRadialAngleOffset] against
  /// whichever label is currently grabbed. A no-op if nothing is grabbed
  /// (shouldn't happen in practice - PartViewport only ever calls this
  /// while [SketchController.draggingLabelId] is non-null, since that's
  /// what [PartViewport.draggingConstraintLabelId] is fed from - but
  /// avoids trusting that invariant blindly).
  void _handleEmbeddedRadialLabelAngleDragged(double angleDegrees) {
    final id = _controller.draggingLabelId;
    if (id == null) return;
    _controller.setRadialAngleOffset(id, angleDegrees);
  }

  /// P52 bug fix (on-device feedback: "when orbiting, linear dimensions
  /// slide along the line"): [PartViewport.onLinearLabelOffsetDragged]'s
  /// handler - [_handleEmbeddedRadialLabelAngleDragged]'s exact sibling for
  /// [SketchController.setLinearOffsetDistance].
  void _handleEmbeddedLinearLabelOffsetDragged(double distance) {
    final id = _controller.draggingLabelId;
    if (id == null) return;
    _controller.setLinearOffsetDistance(id, distance);
  }

  /// P18: [PartViewport.drawGhostPolylines]' data source - tessellates
  /// [SketchController.activeDrawGhost] (already live from
  /// [_handleDrawCursorMoved] above) via [ghostPolylines] into sketch-local
  /// polylines, then maps each point into world space via
  /// [sketchPointToWorld], mirroring exactly how [_buildBaseLayer]'s own
  /// `sketchGeometries` map already embeds this Sketch's *committed*
  /// geometry onto the same [_effectiveOrbitBasis]. Empty (not just null)
  /// when there's no active ghost, matching [PartViewport.drawGhostPolylines]'s
  /// own default.
  List<List<vm.Vector3>> get _embeddedDrawGhostPolylines {
    final basis = _effectiveOrbitBasis;
    if (basis == null) return const [];
    final ghost = _controller.activeDrawGhost;
    if (ghost != null) {
      return [
        for (final polyline in ghostPolylines(ghost))
          [for (final (x, y) in polyline) sketchPointToWorld(basis, x, y)],
      ];
    }
    // On-device feedback ("in the offset tool, a ghost preview should be
    // shown so the user knows which is positive and negative"):
    // [SketchController.activeDrawGhost] is always null in
    // [SketchMode.offset] (only Draw mode ever sets it) - reusing this
    // same prop for [SketchController.offsetPreviewGhosts] instead of
    // adding a parallel one costs nothing (the two are mutually exclusive
    // by mode) and gets the offset preview the exact same rendering this
    // draw-tool ghost already has.
    return [
      for (final offsetGhost in _controller.offsetPreviewGhosts)
        for (final polyline in ghostPolylines(offsetGhost))
          [for (final (x, y) in polyline) sketchPointToWorld(basis, x, y)],
    ];
  }

  /// P20 follow-up: [PartViewport.drawGhostColor]'s data source - green
  /// while [SketchController.activeLineSnapAxis] is set, mirroring
  /// `sketch_canvas.dart`'s own Line horizontal/vertical auto-snap recolor.
  /// Null (the default colour) for every other tool/state.
  vm.Vector4? get _embeddedDrawGhostColor =>
      _controller.activeDrawGhost is LineGhost && _controller.activeLineSnapAxis != null
          ? sketchGhostSnapColor
          : null;

  /// P20 follow-up: [PartViewport.drawGhostGuidePolylines]' data source -
  /// mirrors [_embeddedDrawGhostPolylines] exactly, just through
  /// [ghostGuidePolylines] instead of [ghostPolylines] (currently only ever
  /// non-empty for Polygon's own guide circles).
  List<List<vm.Vector3>> get _embeddedDrawGhostGuidePolylines {
    final basis = _effectiveOrbitBasis;
    final ghost = _controller.activeDrawGhost;
    if (basis == null || ghost == null) return const [];
    return [
      for (final polyline in ghostGuidePolylines(ghost))
        [for (final (x, y) in polyline) sketchPointToWorld(basis, x, y)],
    ];
  }

  /// P20 follow-up: [PartViewport.drawIndicatorMarkers]' data source - the
  /// 3D-embedded counterpart to `sketch_canvas.dart`'s in-progress-anchor/
  /// snap-candidate/midpoint point emphasis (see [DrawIndicatorMarker]'s own
  /// doc comment). Draw-mode only - outside it, [SketchController.
  /// isHoveringOrigin]/[hoveredLineMidpoint] would still resolve non-null
  /// from a stale cursor position, but Select mode already has its own,
  /// unrelated hover-highlight system ([PartViewport.selectedEntities]/
  /// `_hoverHit`) - showing this too would be redundant/conflicting.
  List<DrawIndicatorMarker> get _embeddedDrawIndicatorMarkers {
    final basis = _effectiveOrbitBasis;
    if (basis == null || _controller.mode != SketchMode.draw) return const [];

    vm.Vector3? worldOfPoint(String? pointId) {
      if (pointId == null) return null;
      final point = _controller.points[pointId];
      if (point == null) return null;
      return sketchPointToWorld(basis, point.x, point.y);
    }

    final markers = <DrawIndicatorMarker>[];

    void addAnchor(String? pointId) {
      final world = worldOfPoint(pointId);
      if (world != null) {
        markers.add(DrawIndicatorMarker(
          point: world,
          color: sketchIndicatorAnchorColor,
          width: sketchIndicatorAnchorWidth,
        ));
      }
    }

    // In-progress anchor Points driving whichever multi-tap shape is
    // currently being placed - mirrors sketch_canvas.dart's own deepOrange
    // emphasis markers exactly.
    if (_controller.circleInProgress) addAnchor(_controller.circleCenterPointId);
    if (_controller.arcInProgress) {
      addAnchor(_controller.arcCenterPointId);
      addAnchor(_controller.arcStartPointId);
    }
    if (_controller.polygonInProgress) addAnchor(_controller.polygonCenterPointId);
    if (_controller.slotInProgress) {
      addAnchor(_controller.slotCenter1PointId);
      addAnchor(_controller.slotCenter2PointId);
    }
    if (_controller.ellipseInProgress) {
      addAnchor(_controller.ellipseCenterPointId);
      addAnchor(_controller.ellipseMajorPointId);
    }
    if (_controller.splineInProgress) {
      for (final pointId in _controller.splineThroughPointIds) {
        addAnchor(pointId);
      }
    }

    // Line's chain-start Point - green (about to close the loop) or plain
    // anchor emphasis otherwise, mirroring sketch_canvas.dart's own
    // isChainStart branch exactly.
    if (_controller.chainInProgress) {
      final chainStartWorld = worldOfPoint(_controller.currentChainStartPointId);
      if (chainStartWorld != null) {
        final snapping = _controller.isHoveringChainStart;
        markers.add(DrawIndicatorMarker(
          point: chainStartWorld,
          color: snapping ? sketchIndicatorSnapColor : sketchIndicatorAnchorColor,
          width: snapping ? sketchIndicatorSnapWidth : sketchIndicatorAnchorWidth,
        ));
      }
    }

    // The origin, about to be snapped onto.
    if (_controller.isHoveringOrigin) {
      final originWorld = worldOfPoint(_controller.originPointId);
      if (originWorld != null) {
        markers.add(DrawIndicatorMarker(
          point: originWorld,
          color: sketchIndicatorSnapColor,
          width: sketchIndicatorSnapWidth,
        ));
      }
    }

    // An existing Point the cursor is hovering near (pre-tap candidate) or
    // that the most recent tap just auto-linked onto (post-tap
    // confirmation) - same cyan visual for both, mirroring
    // sketch_canvas.dart's own single _snapCandidateColor for both triggers.
    final candidateWorld = worldOfPoint(_controller.snapCandidatePointId) ??
        worldOfPoint(_controller.autoCoincidentIndicatorPointId);
    if (candidateWorld != null) {
      markers.add(DrawIndicatorMarker(
        point: candidateWorld,
        color: sketchIndicatorCandidateColor,
        width: sketchIndicatorCandidateWidth,
      ));
    }

    // A Line's own (otherwise invisible) midpoint, while the cursor hovers
    // near enough that a tap would snap onto it.
    final midpoint = _controller.hoveredLineMidpoint;
    if (midpoint != null) {
      markers.add(DrawIndicatorMarker(
        point: sketchPointToWorld(basis, midpoint.$1, midpoint.$2),
        color: sketchIndicatorMidpointColor,
        width: sketchIndicatorMidpointWidth,
      ));
    }

    return markers;
  }

  /// P31 (2D-sketcher feature parity): [PartViewport.profileFillOutlines]'
  /// data source - every one of [SketchController.closedProfileFills]'s
  /// outer loops, tessellated via [SketchController.profileLoopOutline].
  /// Mode-independent (unlike [_embeddedDrawIndicatorMarkers], not gated on
  /// [SketchController.mode]), same as `sketch_canvas.dart`'s own
  /// `_paintClosedProfileFill`.
  ///
  /// Cached and content-compared up front (see [_embeddedSketchGeometries]'s
  /// own doc comment for why this discipline is applied to every
  /// [PartViewport] prop from the start now, not retrofitted after an
  /// on-device freeze) - a fresh `List` on every [SketchController]
  /// notification would otherwise force [PartViewport] to rebuild the fill
  /// mesh (a real, if smaller, GPU cost) every tick even when the profile
  /// hasn't changed.
  List<List<(double, double)>> _cachedProfileFillOutlines = const [];

  List<List<(double, double)>> get _embeddedProfileFillOutlines {
    final fresh = <List<(double, double)>>[
      for (final loop in _controller.closedProfileFills)
        if (_controller.profileLoopOutlineWithHoles(loop) case final outline?)
          if (outline.length >= 3) outline,
    ];
    final cached = _cachedProfileFillOutlines;
    if (_profileOutlinesEqual(fresh, cached)) return cached;
    _cachedProfileFillOutlines = fresh;
    return fresh;
  }

  bool _profileOutlinesEqual(List<List<(double, double)>> a, List<List<(double, double)>> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (!listEquals(a[i], b[i])) return false;
    }
    return true;
  }

  /// P31: [PartViewport.profileBranchMarkers]' data source - one red marker
  /// per [SketchController.profileBranchPointIds] entry, mirroring
  /// `sketch_canvas.dart`'s own `_paintProfileBranchPoints`. Mode-independent,
  /// same reasoning as [_embeddedProfileFillOutlines] above. Cached the same
  /// way for the same reason.
  List<DrawIndicatorMarker> _cachedProfileBranchMarkers = const [];

  List<DrawIndicatorMarker> get _embeddedProfileBranchMarkers {
    final basis = _effectiveOrbitBasis;
    if (basis == null) return const [];
    final fresh = <DrawIndicatorMarker>[
      for (final pointId in _controller.profileBranchPointIds)
        if (_controller.points[pointId] case final point?)
          DrawIndicatorMarker(
            point: sketchPointToWorld(basis, point.x, point.y),
            color: sketchProfileBranchMarkerColor,
            width: sketchProfileBranchMarkerWidth,
          ),
    ];
    final cached = _cachedProfileBranchMarkers;
    if (_indicatorMarkersEqual(fresh, cached)) return cached;
    _cachedProfileBranchMarkers = fresh;
    return fresh;
  }

  bool _indicatorMarkersEqual(List<DrawIndicatorMarker> a, List<DrawIndicatorMarker> b) {
    if (a.length != b.length) return false;
    for (var i = 0; i < a.length; i++) {
      if (a[i].point != b[i].point || a[i].color != b[i].color || a[i].width != b[i].width) return false;
    }
    return true;
  }

  /// P32 (2D-sketcher feature parity): [PartViewport.constraintOverlayItems]'
  /// data source. Mode-independent, same as `sketch_canvas.dart`'s own
  /// `_paintDimensionOverlays` (constraints stay visible in every mode, not
  /// just while editing). Cached and content-compared, same reasoning as
  /// [_embeddedProfileFillOutlines] - a fresh `List` every notification
  /// would otherwise force an unconditional overlay repaint on every tick
  /// even when nothing constraint-related changed. [ConstraintOverlayItem]'s
  /// own `==`/`hashCode` (see its doc comment) make [listEquals] a true deep
  /// comparison here, not a reference check.
  List<ConstraintOverlayItem> _cachedConstraintOverlayItems = const [];

  /// P39: [_embeddedConstraintOverlayItems] combines every confirmed
  /// constraint's own overlay with [SketchController.dimensionGhostOverlayItems]'
  /// live, in-progress preview - the exact same two-source combination
  /// `sketch_canvas.dart`'s own paint order already has (`_paintDimensionOverlays`
  /// then `_paintGhosts`), just merged into one list here since
  /// [ConstraintOverlay] takes a single flat list rather than layering two
  /// separate painters.
  List<ConstraintOverlayItem> get _embeddedConstraintOverlayItems {
    final fresh = [
      ..._controller.constraintOverlayItems(),
      ..._controller.dimensionGhostOverlayItems(),
    ];
    final cached = _cachedConstraintOverlayItems;
    if (listEquals(fresh, cached)) return cached;
    _cachedConstraintOverlayItems = fresh;
    return fresh;
  }

  /// P27 bug fix (on-device feedback: Rectangle placement still froze/ANR'd
  /// after the P23 colour-map caching fix below): [PartViewport.
  /// sketchGeometries]' data source used to be built inline, fresh, on
  /// every single call - the *other* half of the exact same "unstable Map
  /// reference forces a full GPU rebuild every frame" bug class the colour
  /// cache below fixes for `sketchEntityColors`, still present here and
  /// apparently still enough on its own to explain the continued freeze
  /// (`PartViewport._syncSketchNodes()`'s own trigger condition ORs
  /// *both* fields together - fixing only one left the other still firing
  /// every rebuild). See [sketchGeometry3DEquals]'s own doc comment for why
  /// a deep content comparison (not `!=`) is required here.
  Map<String, SketchGeometry3D> _cachedEmbeddedSketchGeometries = const {};

  Map<String, SketchGeometry3D> get _embeddedSketchGeometries {
    final basis = _effectiveOrbitBasis;
    if (basis == null) return const {};
    final geometry = sketchGeometry3DFrom(
      basis: basis,
      points: _pointDtosFrom(_controller),
      lines: _lineDtosFrom(_controller),
      circles: _circleDtosFrom(_controller),
      arcs: _arcDtosFrom(_controller),
      ellipses: _ellipseDtosFrom(_controller),
      splines: _splineDtosFrom(_controller),
    );
    final key = _controller.sketchId ?? 'active-sketch';
    // On-device feedback: other sketches share the Body hide/show toggle
    // (see [SketchScreen.otherSketchGeometries]'s own doc comment) - hidden
    // exactly like [widget.bodies] is via `bodiesHidden` a few lines below.
    final others = _referenceBodyHidden ? const <String, SketchGeometry3D>{} : widget.otherSketchGeometries;
    final cached = _cachedEmbeddedSketchGeometries;
    final cachedGeometry = cached[key];
    if (cached.length == others.length + 1 &&
        cachedGeometry != null &&
        sketchGeometry3DEquals(geometry, cachedGeometry) &&
        others.entries.every(
          (e) => cached.containsKey(e.key) && sketchGeometry3DEquals(cached[e.key]!, e.value),
        )) {
      return cached;
    }
    final fresh = {key: geometry, ...others};
    _cachedEmbeddedSketchGeometries = fresh;
    return fresh;
  }

  /// P26 bug fix (on-device feedback: "placing the second point in a
  /// rectangle caused a freeze, then app crash"): [_embeddedSketchEntityColors]
  /// used to build and return a brand-new `Map` instance on every single
  /// call, and `PartViewport`'s own `didUpdateWidget` compares
  /// `sketchEntityColors` by plain `!=` (reference equality - the same
  /// documented contract `sketchGeometries` itself already relies on: "only
  /// build a new Map instance when the content actually changes"). A fresh
  /// instance every rebuild meant *every* `SketchController` notification -
  /// including a plain cursor move that changes no entity's constraint
  /// status at all - looked like a genuine content change, forcing
  /// `_syncSketchNodes()` (a full GPU teardown-and-rebuild of every Line/
  /// Circle/Arc/Ellipse/Spline/Point primitive in the whole Sketch, not
  /// just the entities whose colour actually changed) on every single
  /// frame. Rectangle's own `_buildRectangle` creates ~12 entities
  /// (6 Lines, 4 constraints, a diagonal midpoint constraint, a centre
  /// Point) across a burst of sequential awaited network calls, each
  /// notifying listeners - compounding a full-scene GPU rebuild, on a
  /// rapidly growing entity count, many times in a tight window, which is
  /// almost certainly what actually froze then crashed the app (not a bug
  /// in `_buildRectangle` itself, which is unmodified, shared 2D/3D logic).
  /// Fixed by caching the last-returned `Map` and reusing that exact
  /// reference whenever the freshly-computed content is equal to it -
  /// `PartViewport` then correctly sees "no change" on the (very common)
  /// case where a notification didn't affect anyone's constraint status.
  Map<String, vm.Vector4> _cachedEmbeddedSketchEntityColors = const {};

  /// [PartViewport.sketchEntityColors]' data source - the constraint-status
  /// colour coding `sketch_canvas.dart` has always had, computed the exact
  /// same way (same priority chain, same `SketchController.rigidity`/
  /// `isFullyConstrained`/`isPointForcedOverConstrained` reads) but without
  /// that painter's own selected/hovered/grabbed overrides - Orbit View's
  /// selection highlight is a completely separate overlay system
  /// ([PartViewport.selectedEntities]/its own hover node), layered on top
  /// of this base colour by [PartViewport] itself, so duplicating those
  /// three states here would be redundant. Keyed by entity id (Point/Line/
  /// Circle/Arc/Ellipse/Spline all share one id space), matching
  /// [PartViewport.sketchEntityColors]'s own contract. See
  /// [_cachedEmbeddedSketchEntityColors]'s own doc comment for why this
  /// wraps [_computeEmbeddedSketchEntityColors] in a reference-stabilising
  /// cache rather than returning its result directly.
  Map<String, vm.Vector4> get _embeddedSketchEntityColors {
    final colors = _computeEmbeddedSketchEntityColors();
    if (_sketchEntityColorsEqual(colors, _cachedEmbeddedSketchEntityColors)) {
      return _cachedEmbeddedSketchEntityColors;
    }
    _cachedEmbeddedSketchEntityColors = colors;
    return colors;
  }

  bool _sketchEntityColorsEqual(Map<String, vm.Vector4> a, Map<String, vm.Vector4> b) {
    if (identical(a, b)) return true;
    if (a.length != b.length) return false;
    for (final entry in a.entries) {
      if (b[entry.key] != entry.value) return false;
    }
    return true;
  }

  Map<String, vm.Vector4> _computeEmbeddedSketchEntityColors() {
    final colors = <String, vm.Vector4>{};
    // Bug fix: `SketchController.rigidity` is a fresh graph analysis on
    // every access, not a cached property - the old version of this method
    // called it (directly, or indirectly via `isPointForcedOverConstrained`,
    // which reads it too) dozens of times per call, once or twice per
    // entity. Read once here and reused throughout instead.
    final rigidity = _controller.rigidity;
    final isFullyConstrained = _controller.isFullyConstrained;
    // A Point shared by several entities (e.g. every corner of a
    // Rectangle) would otherwise re-run `isPointForcedOverConstrained`
    // (itself non-trivial - see its own doc comment) once per entity
    // touching it.
    final overConstrainedCache = <String, bool>{};
    bool pointOverConstrained(String pointId) =>
        overConstrainedCache.putIfAbsent(pointId, () => _controller.isPointForcedOverConstrained(pointId));

    // On-device feedback ("lines in sketcher need to be darker - link their
    // colour to the background colour"): [sketchLineColor] is a fixed
    // light-gray constant, low-contrast against some background choices -
    // same bug class the flat 2D canvas's `_unconstrainedColor` had, fixed
    // the same way here: derived from the 3D viewport's own real,
    // user-configurable background ([ViewPreferences.bgColourHex]) via the
    // same light/dark threshold Flutter's `ThemeData` uses for
    // on-primary-color text, rather than a fixed mid-tone that can wash out
    // against either a light or dark background.
    final embeddedBackground = colorFromHex(ViewPreferences.bgColourHex);
    final embeddedUnconstrainedColor =
        ThemeData.estimateBrightnessForColor(embeddedBackground) == Brightness.light
            ? vm.Vector4(0, 0, 0, 1)
            : vm.Vector4(1, 1, 1, 1);

    vm.Vector4 statusColor({required bool overConstrained, required bool construction, required bool fullyConstrained}) {
      if (overConstrained) return sketchOverConstrainedColor;
      if (construction) return sketchConstructionColor;
      if (fullyConstrained) return sketchFullyConstrainedColor;
      return embeddedUnconstrainedColor;
    }

    for (final line in _controller.lines.values) {
      final overConstrained = rigidity.isSegmentOverConstrained(line.startPointId, line.endPointId) ||
          pointOverConstrained(line.startPointId) ||
          pointOverConstrained(line.endPointId);
      final fullyConstrained =
          isFullyConstrained || rigidity.isSegmentFullyConstrained(line.startPointId, line.endPointId);
      colors[line.id] =
          statusColor(overConstrained: overConstrained, construction: line.construction, fullyConstrained: fullyConstrained);
    }

    for (final circle in _controller.circles.values) {
      final overConstrained = rigidity.isSegmentOverConstrained(circle.centerPointId, circle.radiusPointId) ||
          pointOverConstrained(circle.centerPointId) ||
          pointOverConstrained(circle.radiusPointId);
      final fullyConstrained =
          isFullyConstrained || rigidity.isSegmentFullyConstrained(circle.centerPointId, circle.radiusPointId);
      colors[circle.id] = statusColor(
          overConstrained: overConstrained, construction: circle.construction, fullyConstrained: fullyConstrained);
    }

    for (final arc in _controller.arcs.values) {
      final overConstrained = rigidity.isSegmentOverConstrained(arc.centerPointId, arc.startPointId) ||
          rigidity.isSegmentOverConstrained(arc.centerPointId, arc.endPointId) ||
          pointOverConstrained(arc.centerPointId) ||
          pointOverConstrained(arc.startPointId) ||
          pointOverConstrained(arc.endPointId);
      final fullyConstrained = isFullyConstrained ||
          (rigidity.isSegmentFullyConstrained(arc.centerPointId, arc.startPointId) &&
              rigidity.isSegmentFullyConstrained(arc.centerPointId, arc.endPointId));
      colors[arc.id] =
          statusColor(overConstrained: overConstrained, construction: arc.construction, fullyConstrained: fullyConstrained);
    }

    for (final ellipse in _controller.ellipses.values) {
      final overConstrained = rigidity.isSegmentOverConstrained(ellipse.centerPointId, ellipse.majorPointId) ||
          rigidity.isSegmentOverConstrained(ellipse.centerPointId, ellipse.minorPointId) ||
          pointOverConstrained(ellipse.centerPointId) ||
          pointOverConstrained(ellipse.majorPointId) ||
          pointOverConstrained(ellipse.minorPointId);
      final fullyConstrained = isFullyConstrained ||
          (rigidity.isSegmentFullyConstrained(ellipse.centerPointId, ellipse.majorPointId) &&
              rigidity.isSegmentFullyConstrained(ellipse.centerPointId, ellipse.minorPointId));
      colors[ellipse.id] = statusColor(
          overConstrained: overConstrained, construction: ellipse.construction, fullyConstrained: fullyConstrained);
    }

    for (final spline in _controller.splines.values) {
      var overConstrained = false;
      var fullyConstrainedSpline = true;
      for (final pointId in spline.throughPointIds) {
        if (pointOverConstrained(pointId)) overConstrained = true;
      }
      for (var i = 0; i < spline.throughPointIds.length - 1; i++) {
        final a = spline.throughPointIds[i];
        final b = spline.throughPointIds[i + 1];
        if (rigidity.isSegmentOverConstrained(a, b)) overConstrained = true;
        if (!rigidity.isSegmentFullyConstrained(a, b)) fullyConstrainedSpline = false;
      }
      fullyConstrainedSpline = isFullyConstrained || fullyConstrainedSpline;
      colors[spline.id] = statusColor(
          overConstrained: overConstrained, construction: spline.construction, fullyConstrained: fullyConstrainedSpline);
    }

    // Points don't carry their own construction/over-constrained state
    // beyond what SketchController.isPointForcedOverConstrained/rigidity
    // already report per-id - mirrors sketch_canvas.dart's own point loop,
    // minus the origin (kept at the default colour here, same as 2D's own
    // dedicated indigo origin marker never participating in this scheme).
    for (final point in _controller.points.values) {
      if (point.id == _controller.originPointId) continue;
      final fullyConstrained = isFullyConstrained || rigidity.isPointFullyConstrained(point.id);
      colors[point.id] = statusColor(
        overConstrained: pointOverConstrained(point.id),
        construction: false,
        fullyConstrained: fullyConstrained,
      );
    }

    // P24: the currently-grabbed Point/Line (see [_dragModeActiveInOrbitView])
    // wins over every status colour above - applied last, mirrors 2D's own
    // grabbed > selected > hovered > over-constrained > ... priority chain
    // (Orbit View's selected/hover highlight is a separate overlay layered
    // on top by PartViewport itself, so only "grabbed" needs replicating
    // here).
    final draggingPointId = _controller.draggingPointId;
    if (draggingPointId != null) colors[draggingPointId] = sketchGrabbedColor;
    final draggingLineId = _controller.draggingLineId;
    if (draggingLineId != null) colors[draggingLineId] = sketchGrabbedColor;

    return colors;
  }

  /// The "Return to Default View" FAB's action - re-orients the embedded
  /// [PartViewport]'s camera to look straight at the Sketch's own plane,
  /// animated, reusing [PartViewportState.animateToBasis] exactly as the 3D
  /// viewport already does for its camera-into-sketch transition (fixed or
  /// custom plane alike - see [_effectiveOrbitBasis]). Stays in Orbit View
  /// rather than exiting it - leaving is the toggle FAB's job.
  void _returnOrbitToDefaultView() {
    final orbitBasis = _effectiveOrbitBasis;
    if (orbitBasis == null) return;
    _orbitViewportKey.currentState?.animateToBasis(orbitBasis);
  }

  /// On-device feedback: entering Orbit View should always start at 4.1's
  /// ~25% transparent default, not whatever [_orbitBodyOpacity] was left at
  /// from a previous Orbit View session on this same Sketch - each entry is
  /// a fresh, predictable "temporary inspection mode" (see
  /// [_buildBaseLayer]'s doc comment), not one that carries state forward.
  ///
  /// On-device feedback ("point tool shouldn't start when opening a
  /// sketch"): resets to Select mode, not a specific draw tool - every
  /// draw tool `SketchSpeedDial.restrictToEmbeddedTools` allows now (P20)
  /// works fine in Orbit View, so there's no longer a "guarantee some tool
  /// that actually works here" reason to force one; Select mode is itself
  /// fully supported (P16) and is the more natural "just opened, haven't
  /// chosen anything yet" starting point. Still guards against a stale
  /// Dimension/Trim mode carried over on a reused, externally-injected
  /// controller (see this class's own `dispose` doc comment for when that
  /// applies) - both are still 2D-only, so Orbit View must never start in
  /// either.
  void _enterOrbitView() {
    if (_controller.mode != SketchMode.select) {
      _controller.exitToSelectMode();
    }
    setState(() {
      _orbitViewActive = true;
      _orbitBodyOpacity = 0.75;
      // P19 on-device feedback: "Cursor-first" - every fresh entry starts
      // ready to draw/select precisely, not in plain-orbit sub-mode.
      _orbitCursorActive = true;
    });
  }

  /// Stage 23f: the hamburger menu's content - a View submenu for the
  /// constraint-label-visibility toggle and the canvas colour/transparency
  /// controls. Exit Sketch lives in its own dedicated FAB (top-right of the
  /// canvas) rather than as an entry here, so it isn't repeated.
  ///
  /// `shrinkWrap: true` so this sizes to its own (short) content within
  /// whatever [ConstrainedBox] the caller (the menu overlay above) wraps it
  /// in, rather than trying to fill it - the previous [Drawer]-based
  /// version couldn't do this at all, since a [Drawer] forces its content
  /// to the full screen height regardless.
  Widget _buildMenuPanel(BuildContext context) {
    const density = VisualDensity(horizontal: -4, vertical: -4);
    const titleStyle = TextStyle(fontSize: 13);
    return ListView(
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      children: [
        if (widget.standalone) _buildStandaloneFileMenu(context, density, titleStyle),
        if (_orbitViewActive)
          _build3DViewMenu(context, density, titleStyle, showBodyTransparency: true)
        else
          _build2DViewMenu(context, density, titleStyle),
      ],
    );
  }

  /// The standalone "2D Drawing" tool's own File section - Save/Open for
  /// this Sketch's own local file, in place of the Part-level native file
  /// format a Part-anchored Sketch relies on (`part_screen.dart`'s own File
  /// menu) - see [SketchScreen.standalone]'s own doc comment.
  Widget _buildStandaloneFileMenu(BuildContext context, VisualDensity density, TextStyle titleStyle) {
    return ExpansionTile(
      dense: true,
      visualDensity: density,
      leading: const Icon(Icons.folder_outlined, size: 20),
      title: Text('File', style: titleStyle),
      initiallyExpanded: true,
      children: [
        ListTile(
          dense: true,
          visualDensity: density,
          leading: const Icon(Icons.save_outlined, size: 20),
          title: Text('Save', style: titleStyle),
          onTap: _saveStandaloneSketch,
        ),
        ListTile(
          dense: true,
          visualDensity: density,
          leading: const Icon(Icons.folder_open_outlined, size: 20),
          title: Text('Open', style: titleStyle),
          onTap: _openStandaloneSketch,
        ),
      ],
    );
  }

  Widget _build2DViewMenu(BuildContext context, VisualDensity density, TextStyle titleStyle) {
    return ExpansionTile(
      dense: true,
      visualDensity: density,
      leading: const Icon(Icons.visibility_outlined, size: 20),
      title: Text('View', style: titleStyle),
      initiallyExpanded: true,
      children: [
        SwitchListTile(
          dense: true,
          visualDensity: density,
          title: Text('Constraint Labels', style: titleStyle),
          value: _constraintLabelsVisible,
          onChanged: (value) => setState(() => _constraintLabelsVisible = value),
        ),
        ListTile(
          dense: true,
          visualDensity: density,
          // On-device feedback: used to tint this glyph to match the
          // selected canvas colour, which made it disappear entirely
          // against a similarly-light background (e.g. the default white/
          // near-white swatches) - a fixed colour, matching every other
          // menu row's icon here, keeps it always legible regardless of
          // what's currently selected.
          leading: const Icon(Icons.palette_outlined, size: 20),
          title: Text('Canvas Colour', style: titleStyle),
          onTap: () => _pickCanvasColor(context),
        ),
      ],
    );
  }

  /// Orbit View's own View submenu - on-device feedback: "view options
  /// should be available as in the 3D viewport [...] body colour,
  /// transparency, edges, shaded, wireframe", mirroring
  /// `PartToolbar._buildViewMenu`'s render-mode list and Body Colour/
  /// Transparency entries exactly (reusing the same [showColourSwatchSheet]/
  /// [showBodyOpacitySheet] helpers), scoped down to just what applies to a
  /// read-only embedded viewport - no far clip/perspective/background
  /// colour/scene lighting controls, since those aren't part of the ask and
  /// Orbit View has no persisted preferences of its own to expose them via.
  Widget _build3DViewMenu(
    BuildContext context,
    VisualDensity density,
    TextStyle titleStyle, {
    required bool showBodyTransparency,
  }) {
    return ExpansionTile(
      dense: true,
      visualDensity: density,
      leading: const Icon(Icons.view_in_ar, size: 20),
      title: Text('3D View', style: titleStyle),
      initiallyExpanded: true,
      children: [
        for (final mode in ViewportRenderMode.values)
          ListTile(
            dense: true,
            visualDensity: density,
            leading: SvgIcon(mode.svgAsset, size: 26),
            title: Text(mode.label, style: titleStyle),
            trailing: mode == _orbitRenderMode ? const Icon(Icons.check, size: 18) : null,
            onTap: () => setState(() => _orbitRenderMode = mode),
          ),
        ListTile(
          dense: true,
          visualDensity: density,
          // A fixed multi-colour glyph, not tinted via ColorFilter like
          // every other icon here - deliberately picked over the
          // tintable/live-color-swatch alternatives so the icon always
          // reads as "colour picker" at a glance; the current selection
          // itself is only ever shown in the picker sheet this opens, not
          // baked into this leading icon.
          leading: SvgPicture.asset(
            'assets/icons/sketchbar/sketchbar_body_colour_cube.svg',
            width: 26,
            height: 26,
          ),
          title: Text('Body Colour', style: titleStyle),
          onTap: () async {
            final hex = await showColourSwatchSheet(
              context,
              title: 'Body Colour',
              swatches: bodyColourSwatches,
              selectedHex: _orbitBodyColourHex,
            );
            if (hex != null) setState(() => _orbitBodyColourHex = hex);
          },
        ),
        if (showBodyTransparency)
          ListTile(
            dense: true,
            visualDensity: density,
            leading: SvgPicture.asset(
              'assets/icons/sketchbar/sketchbar_body_transparency.svg',
              width: 26,
              height: 26,
              colorFilter: ColorFilter.mode(
                Theme.of(context).colorScheme.onSurface,
                BlendMode.srcIn,
              ),
            ),
            title: Text('Body Transparency', style: titleStyle),
            onTap: () async {
              final opacity = await showBodyOpacitySheet(context, initialOpacity: _orbitBodyOpacity);
              if (opacity != null) setState(() => _orbitBodyOpacity = opacity);
            },
          ),
        ListTile(
          dense: true,
          visualDensity: density,
          leading: const Icon(Icons.palette_outlined, size: 20),
          title: Text('Canvas Colour', style: titleStyle),
          onTap: () async {
            final hex = await showColourSwatchSheet(
              context,
              title: 'Canvas Colour',
              swatches: backgroundColourSwatches,
              selectedHex: _orbitCanvasColourHex,
            );
            if (hex != null) setState(() => _orbitCanvasColourHex = hex);
          },
        ),
        ListTile(
          dense: true,
          visualDensity: density,
          leading: const Icon(Icons.opacity, size: 20),
          title: Text('Canvas Transparency', style: titleStyle),
          onTap: () async {
            final opacity = await showBodyOpacitySheet(context, initialOpacity: _orbitCanvasOpacity);
            if (opacity != null) setState(() => _orbitCanvasOpacity = opacity);
          },
        ),
        SwitchListTile(
          dense: true,
          visualDensity: density,
          title: Text('Grid', style: titleStyle),
          value: _orbitGridVisible,
          onChanged: (value) => setState(() => _orbitGridVisible = value),
        ),
      ],
    );
  }

  static const List<Color> _canvasColorSwatches = [
    SketchCanvas.defaultColor,
    Color(0xFFFFFFFF),
    Color(0xFFE8F0FE),
    Color(0xFF2C2C2C),
    Color(0xFF1E1E2E),
  ];

  Future<void> _pickCanvasColor(BuildContext context) async {
    final chosen = await showModalBottomSheet<Color>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Wrap(
            spacing: 20,
            runSpacing: 16,
            children: [
              for (final color in _canvasColorSwatches)
                _CanvasColorSwatch(
                  color: color,
                  selected: color == _canvasColor,
                  onTap: () => Navigator.of(sheetContext).pop(color),
                ),
            ],
          ),
        ),
      ),
    );
    if (chosen != null) setState(() => _canvasColor = chosen);
  }

  /// The standalone "2D Drawing" tool's own Save - see [SketchScreen.
  /// standalone]'s own doc comment for why a bare Sketch needs a local
  /// file at all (it has no Part to be saved as part of, unlike every
  /// other Sketch in this app). Mirrors `part_screen.dart`'s
  /// `_exportAndSaveNativeFile` shape exactly (export -> JSON-encode ->
  /// `FilePicker.platform.saveFile`), just calling `SketchApiClient.
  /// exportSketch` instead of the Part-level native-file export.
  String? _lastSavedSketchFileName;

  Future<void> _saveStandaloneSketch() async {
    setState(() => _menuOpen = false);
    final sketchId = _controller.sketchId;
    if (sketchId == null) return;
    try {
      final data = await _controller.api.exportSketch(sketchId);
      final bytes = Uint8List.fromList(utf8.encode(jsonEncode(data)));
      final savedPath = await FilePicker.platform.saveFile(
        dialogTitle: 'Save Drawing',
        fileName: _lastSavedSketchFileName ?? 'drawing.DIDSAsketch',
        bytes: bytes,
      );
      if (savedPath != null) {
        _lastSavedSketchFileName = savedPath.split('/').last;
      }
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Save failed: ${e.message}')));
    }
  }

  /// [_saveStandaloneSketch]'s inverse - reads a local file the user picks
  /// and imports it as a brand-new Sketch (`SketchApiClient.importSketch`,
  /// always a fresh id server-side - see that method's own doc comment),
  /// then pushes a fresh, standalone [SketchScreen] adopting it. Pushing a
  /// new screen rather than reloading this one in place mirrors
  /// `part_screen.dart`'s own `_openNativeFile`/`PartScreen.initialPartId`
  /// precedent for the identical reason - a clean, fully-reset State for
  /// the newly opened content, not a partially-reused one.
  Future<void> _openStandaloneSketch() async {
    setState(() => _menuOpen = false);
    final result = await FilePicker.platform.pickFiles(withData: true, type: FileType.any);
    if (result == null || result.files.isEmpty || !mounted) return;
    final bytes = result.files.single.bytes;
    if (bytes == null) return;

    Map<String, dynamic> decoded;
    try {
      decoded = jsonDecode(utf8.decode(bytes)) as Map<String, dynamic>;
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('Not a valid drawing file')));
      return;
    }

    SketchDto? imported;
    try {
      imported = await _controller.api.importSketch(decoded);
    } on ApiException catch (e) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Open failed: ${e.message}')));
      return;
    }
    if (!mounted) return;

    await Navigator.of(context).pushReplacement(
      MaterialPageRoute(builder: (context) => SketchScreen(adoptSketchId: imported!.id, standalone: true)),
    );
  }
}

/// One tappable swatch in [_SketchScreenState._pickCanvasColor]'s sheet -
/// mirrors `viewport3d/view_prefs_sheets.dart`'s `_SwatchTile`, but plain
/// [Color] rather than a persisted `"#RRGGBB"` string, since this is
/// session-only.
class _CanvasColorSwatch extends StatelessWidget {
  final Color color;
  final bool selected;
  final VoidCallback onTap;

  const _CanvasColorSwatch({required this.color, required this.selected, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: color,
          shape: BoxShape.circle,
          border: Border.all(
            color: selected ? Theme.of(context).colorScheme.primary : Colors.grey,
            width: selected ? 3 : 1,
          ),
        ),
        child: selected ? const Icon(Icons.check) : null,
      ),
    );
  }
}

