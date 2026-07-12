import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';

import '../api/document_api_client.dart' show BodyMeshDto;
import '../api/sketch_api_client.dart' show ArcDto, CircleDto, EllipseDto, LineDto, PointDto, SplineDto;
import '../didsa_logo_button.dart';
import '../viewport3d/part_viewport.dart';
import '../viewport3d/reference_planes.dart';
import '../viewport3d/render_mode.dart';
import '../viewport3d/sketch_geometry_3d.dart';
import '../viewport3d/svg_icon.dart';
import '../viewport3d/view_prefs_sheets.dart';
import '../viewport3d/view_preferences.dart';
import 'sketch_canvas.dart';
import 'sketch_construction_method_bar.dart';
import 'sketch_controller.dart';
import 'sketch_dimension_bar.dart';
import 'sketch_ribbon.dart';
import 'sketch_speed_dial.dart';
import 'sketch_viewport.dart' show SketchViewport;

/// Phase 4.1/4.2: converts [controller]'s live points into the
/// [PointDto]/[LineDto]/[CircleDto] shapes [sketchGeometry3DFrom] expects -
/// needed because [SketchController]'s own `SketchPointView`/`SketchLineView`/
/// `SketchCircleView` are a distinct, unsaved-state-oriented set of types
/// that don't carry the `length`/`radius` fields those DTOs do (the backend
/// computes those; the live client-side views don't store them), so they're
/// recomputed here via plain distance formulas.
List<PointDto> _pointDtosFrom(SketchController controller) => [
      for (final p in controller.points.values) PointDto(id: p.id, x: p.x, y: p.y),
    ];

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
  });

  @override
  State<SketchScreen> createState() => _SketchScreenState();
}

class _SketchScreenState extends State<SketchScreen> {
  late final SketchController _controller;

  /// Stage 12 item 9's Hide/Show Reference Body toggle - in-memory only,
  /// same as PartScreen's `_referencePlanesHidden`. Defaults to shown.
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
  double _canvasOpacity = 1.0;

  /// Phase 4.2's Orbit View toggle: look-only, 2D editing stays disabled
  /// while active (see [_buildBaseLayer]'s doc comment). Session-only, same
  /// as the other view-preference fields above.
  bool _orbitViewActive = false;

  /// Lets [_returnOrbitToDefaultView] drive the embedded [PartViewport]'s
  /// own [PartViewportState.animateToPlane] - the only way to control its
  /// internally-owned [OrbitCamera] from outside (see
  /// `viewport3d/orbit_camera.dart`: no camera is ever injectable).
  final GlobalKey<PartViewportState> _orbitViewportKey = GlobalKey<PartViewportState>();

  /// Same idea as [_orbitViewportKey], for the *other* embedded
  /// [PartViewport] - the shaded-body backdrop behind the flat 2D canvas
  /// (see [_buildBaseLayer]) - so [_syncBackdropCamera] can drive its
  /// camera via [PartViewportState.syncToSketchViewport] as the 2D canvas
  /// pans/zooms.
  final GlobalKey<PartViewportState> _backdropViewportKey = GlobalKey<PartViewportState>();

  /// On-device feedback: both embedded [PartViewport]s (Orbit View and the
  /// 2D canvas's own shaded-body backdrop) share these same View
  /// preferences - render mode, body colour - so switching between the two
  /// contexts looks consistent; see [_build3DViewMenu], now reachable
  /// whether or not Orbit View is active (see [_buildMenuPanel]). All
  /// session-only, same as the 2D canvas's own view preferences above.
  /// [_orbitRenderMode] defaults to `shadedWithEdges` (on-device feedback:
  /// edges should be visible by default) in both contexts.
  /// [_orbitBodyOpacity] only applies to Orbit View's own body material
  /// (the backdrop's body stays fully opaque - see [_buildBaseLayer]'s doc
  /// comment for why) and defaults to 4.1's "~25% transparent" ask,
  /// overriding [ViewPreferences.defaultBodyOpacity]'s `1.0` rather than
  /// reusing the Part viewport's own persisted preference.
  ViewportRenderMode _orbitRenderMode = ViewportRenderMode.shadedWithEdges;
  String _orbitBodyColourHex = ViewPreferences.defaultBodyColourHex;
  double _orbitBodyOpacity = 0.75;

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
    // On-device feedback: when this Sketch's Part has real Body geometry to
    // show behind the canvas (see _buildBaseLayer's body backdrop), default
    // Canvas Transparency to ~25% so it's actually visible without the user
    // needing to find the View menu first - a bodyless Sketch keeps the
    // fully-opaque default, since there would be nothing to reveal anyway.
    if (widget.bodies.isNotEmpty) {
      _canvasOpacity = 0.75;
    }
  }

  @override
  void dispose() {
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
                          if (widget.referenceGhostSegments.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'reference-body-visibility-fab',
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
                          // Phase 4.2: only offered once the Sketch's plane
                          // has loaded and resolves to one of the three fixed
                          // ReferencePlaneKinds - a custom-plane Sketch has no
                          // orientationFacingPlane equivalent yet (matches
                          // the same limitation _openSketchWithAnimation
                          // already has for those Sketches), and there's
                          // nothing to orbit toward before the plane loads.
                          AnimatedBuilder(
                            animation: _controller,
                            builder: (context, _) {
                              if (_planeKind == null) {
                                return const SizedBox.shrink();
                              }
                              final theme = Theme.of(context);
                              return Padding(
                                padding: const EdgeInsets.only(top: 8),
                                child: FloatingActionButton.small(
                                  heroTag: 'orbit-view-toggle-fab',
                                  tooltip: _orbitViewActive ? 'Exit Orbit View' : 'Orbit View',
                                  backgroundColor: _orbitViewActive ? theme.colorScheme.primary : null,
                                  foregroundColor: _orbitViewActive ? theme.colorScheme.onPrimary : null,
                                  onPressed: _orbitViewActive ? _exitOrbitView : _enterOrbitView,
                                  child: SvgPicture.asset(
                                    'assets/icons/sketchbar/sketchbar_orbit_view.svg',
                                    width: 30,
                                    height: 30,
                                    colorFilter: ColorFilter.mode(
                                      _orbitViewActive
                                          ? theme.colorScheme.onPrimary
                                          : theme.colorScheme.onPrimaryContainer,
                                      BlendMode.srcIn,
                                    ),
                                  ),
                                ),
                              );
                            },
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
                  // Hidden during Orbit View (Phase 4.2 is look-only -
                  // editing always happens back on the 2D canvas).
                  if (!_orbitViewActive) Positioned.fill(child: SketchRibbon(controller: _controller)),
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
                          if (_controller.mode == SketchMode.select || _orbitViewActive) {
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
                  // Bottom-right: the draw/dimension tool speed dial, or -
                  // while Orbit View is active - the "Return to Default
                  // View" button instead, since there's nothing to draw
                  // while look-only. Unlike the toggle FAB above, this one
                  // *animates*: it calls the same animateToPlane the 3D
                  // viewport already uses for its own camera-into-sketch
                  // transition, re-orienting the embedded PartViewport back
                  // to looking straight at the Sketch's plane without
                  // leaving Orbit View.
                  Positioned(
                    right: 16,
                    bottom: 16,
                    child: _orbitViewActive
                        ? FloatingActionButton.small(
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
                          )
                        : SketchSpeedDial(controller: _controller),
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
                        if (_controller.mode != SketchMode.select || _orbitViewActive) {
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
                        final showConstructionBar = mode == SketchMode.draw;
                        final visible = (showConstructionBar || mode == SketchMode.dimension) && !_orbitViewActive;
                        final bar = mode == SketchMode.dimension
                            ? SketchDimensionBar(controller: _controller)
                            : SketchConstructionMethodBar(controller: _controller);
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

  /// Whether the shaded-body backdrop (see [_buildBaseLayer]) applies right
  /// now - outside Orbit View (which already shows bodies its own way),
  /// with a resolved plane and at least one Body to show, and not
  /// explicitly hidden via the Hide/Show Reference Body toggle. Shared
  /// between [_buildBaseLayer] (whether to render it) and [_buildMenuPanel]
  /// (whether to offer its View controls).
  bool get _hasBodyBackdrop =>
      !_orbitViewActive && _planeKind != null && widget.bodies.isNotEmpty && !_referenceBodyHidden;

  /// Phase 4.1/4.2: the Stack's base layer.
  ///
  /// While [_orbitViewActive]: a read-only, look-only 3D [PartViewport]
  /// embedding [widget.bodies] (shaded, at [_orbitBodyOpacity]) alongside
  /// this Sketch's own geometry, reusing `viewport3d/sketch_geometry_3d.dart`'s
  /// existing projection - "so the user can see where they are sketching"
  /// relative to the real part, per the brief. Editing always stays on the
  /// 2D canvas (see the scope doc's "Decided: look-only toggle" note) -
  /// `onPlaneTap`/`onBackgroundTap` are no-ops and `selectionMode` stays
  /// false, so orbiting is the only interaction available here.
  ///
  /// Otherwise: the flat 2D [SketchCanvas], with (on-device feedback) a
  /// second, static shaded-body backdrop behind it whenever [_hasBodyBackdrop] -
  /// non-interactive (pointer events ignored - it never orbits itself) and
  /// fully opaque itself, letting the *canvas*'s own [_canvasOpacity] do
  /// the fading instead. On-device feedback: this backdrop's camera used
  /// to be set once (via `initialViewPlane`) and never move again, so its
  /// scale/framing had no relationship at all to the 2D canvas's own
  /// pan/zoom - [_syncBackdropCamera] now keeps it tracking the 2D
  /// canvas's `onViewportChanged` callback continuously.
  Widget _buildBaseLayer() {
    final planeKind = _planeKind;
    if (_orbitViewActive && planeKind != null) {
      return PartViewport(
        key: _orbitViewportKey,
        bodies: widget.bodies,
        selectedPlane: null,
        onPlaneTap: (_) {},
        onBackgroundTap: () {},
        sketchGeometries: {
          // Bug fix: was SketchPlaneBasis.fixed(planeKind), silently
          // discarding this Sketch's own orientation - drew the user's own
          // geometry in the wrong 3D position relative to the real body
          // backdrop whenever flip/rotationQuarterTurns wasn't the default.
          (_controller.sketchId ?? 'active-sketch'): sketchGeometry3DFrom(
            basis: SketchPlaneBasis.oriented(
              planeKind,
              flip: _controller.flip,
              rotationQuarterTurns: _controller.rotationQuarterTurns,
            ),
            points: _pointDtosFrom(_controller),
            lines: _lineDtosFrom(_controller),
            circles: _circleDtosFrom(_controller),
            arcs: _arcDtosFrom(_controller),
            ellipses: _ellipseDtosFrom(_controller),
            splines: _splineDtosFrom(_controller),
          ),
        },
        referencePlanesHidden: true,
        renderMode: _orbitRenderMode,
        bodyColourHex: _orbitBodyColourHex,
        bodyOpacity: _orbitBodyOpacity,
        initialViewPlane: planeKind,
        initialViewFlip: _controller.flip,
        initialViewRotationQuarterTurns: _controller.rotationQuarterTurns,
      );
    }
    return Stack(
      children: [
        if (_hasBodyBackdrop)
          Positioned.fill(
            child: IgnorePointer(
              child: PartViewport(
                key: _backdropViewportKey,
                bodies: widget.bodies,
                selectedPlane: null,
                onPlaneTap: (_) {},
                onBackgroundTap: () {},
                referencePlanesHidden: true,
                renderMode: _orbitRenderMode,
                bodyColourHex: _orbitBodyColourHex,
                initialViewPlane: planeKind,
                initialViewFlip: _controller.flip,
                initialViewRotationQuarterTurns: _controller.rotationQuarterTurns,
              ),
            ),
          ),
        SketchCanvas(
          controller: _controller,
          referenceGhostSegments: widget.referenceGhostSegments,
          referenceGhostVertices: widget.referenceGhostVertices,
          referenceGhostEdges: widget.referenceGhostEdges,
          referenceBodyHidden: _referenceBodyHidden,
          constraintLabelsVisible: _constraintLabelsVisible,
          canvasColor: _canvasColor,
          canvasOpacity: _canvasOpacity,
          onViewportChanged: _hasBodyBackdrop ? _syncBackdropCamera : null,
        ),
      ],
    );
  }

  /// Keeps the shaded-body backdrop's camera exactly matching what the 2D
  /// canvas above it is currently showing - see
  /// [PartViewportState.syncToSketchViewport]'s own doc comment for the
  /// underlying maths. `zoom` -> `pixelsPerUnit` mirrors
  /// `SketchViewport.transformFor`'s own `basePixelsPerUnit * zoom`
  /// exactly, so the two stay pixel-for-pixel in step.
  void _syncBackdropCamera(Offset panOffset, double zoom, Size canvasSize) {
    final planeKind = _planeKind;
    if (planeKind == null) return;
    _backdropViewportKey.currentState?.syncToSketchViewport(
      plane: planeKind,
      pixelsPerUnit: SketchViewport.basePixelsPerUnit * zoom,
      panOffsetPx: panOffset,
      canvasSize: canvasSize,
      flip: _controller.flip,
      rotationQuarterTurns: _controller.rotationQuarterTurns,
    );
  }

  /// The "Return to Default View" FAB's action - re-orients the embedded
  /// [PartViewport]'s camera to look straight at the Sketch's own plane,
  /// animated, reusing [PartViewportState.animateToPlane] exactly as the 3D
  /// viewport already does for its camera-into-sketch transition. Stays in
  /// Orbit View rather than exiting it - leaving is the toggle FAB's job.
  void _returnOrbitToDefaultView() {
    final planeKind = _planeKind;
    if (planeKind == null) return;
    _orbitViewportKey.currentState?.animateToPlane(
      planeKind,
      flip: _controller.flip,
      rotationQuarterTurns: _controller.rotationQuarterTurns,
    );
  }

  /// On-device feedback: entering Orbit View should always start at 4.1's
  /// ~25% transparent default, not whatever [_orbitBodyOpacity] was left at
  /// from a previous Orbit View session on this same Sketch - each entry is
  /// a fresh, predictable "temporary inspection mode" (see
  /// [_buildBaseLayer]'s doc comment), not one that carries state forward.
  void _enterOrbitView() {
    setState(() {
      _orbitViewActive = true;
      _orbitBodyOpacity = 0.75;
    });
  }

  /// Guards [_exitOrbitView] against overlapping camera animations if the
  /// toggle FAB is tapped again mid-exit.
  bool _orbitViewExiting = false;

  /// On-device feedback: leaving Orbit View should animate the camera back
  /// to facing the Sketch's plane *before* swapping back to the flat 2D
  /// canvas - reusing the same [PartViewportState.animateToPlane] call
  /// [_returnOrbitToDefaultView] uses - rather than cutting away instantly
  /// from whatever angle the user had orbited to.
  Future<void> _exitOrbitView() async {
    if (_orbitViewExiting) return;
    _orbitViewExiting = true;
    final planeKind = _planeKind;
    if (planeKind != null) {
      await _orbitViewportKey.currentState?.animateToPlane(
        planeKind,
        flip: _controller.flip,
        rotationQuarterTurns: _controller.rotationQuarterTurns,
      );
    }
    _orbitViewExiting = false;
    if (!mounted) return;
    setState(() => _orbitViewActive = false);
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
        if (_orbitViewActive)
          _build3DViewMenu(context, density, titleStyle, showBodyTransparency: true)
        else ...[
          _build2DViewMenu(context, density, titleStyle),
          // On-device feedback: "there aren't view options when I'm in
          // sketch mode" - the shaded-body backdrop's own render
          // mode/body colour need to be reachable without switching to
          // Orbit View first. Body Transparency is deliberately left out
          // here - the backdrop's own body material always stays fully
          // opaque (see [_buildBaseLayer]'s doc comment); Canvas
          // Transparency, in the section above, is the real transparency
          // control for this context.
          if (_hasBodyBackdrop) _build3DViewMenu(context, density, titleStyle, showBodyTransparency: false),
        ],
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
          title: Text('Canvas Transparency', style: titleStyle),
          onTap: () => _pickCanvasOpacity(context),
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

  Future<void> _pickCanvasOpacity(BuildContext context) async {
    final opacity = await showModalBottomSheet<double>(
      context: context,
      builder: (sheetContext) => _CanvasOpacitySheet(initialOpacity: _canvasOpacity),
    );
    if (opacity != null) setState(() => _canvasOpacity = opacity);
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

/// Stage 23f's canvas transparency slider - mirrors
/// `viewport3d/view_prefs_sheets.dart`'s `_BodyOpacitySheet` (0% = fully
/// opaque, 100% = fully transparent, 5% steps), but pops the chosen
/// *opacity* directly rather than going through [ViewPreferences].
class _CanvasOpacitySheet extends StatefulWidget {
  final double initialOpacity;
  const _CanvasOpacitySheet({required this.initialOpacity});

  @override
  State<_CanvasOpacitySheet> createState() => _CanvasOpacitySheetState();
}

class _CanvasOpacitySheetState extends State<_CanvasOpacitySheet> {
  late double _opacity;

  @override
  void initState() {
    super.initState();
    _opacity = widget.initialOpacity;
  }

  @override
  Widget build(BuildContext context) {
    final transparencyPercent = ((1 - _opacity) * 100).round();
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text('Canvas Transparency', style: Theme.of(context).textTheme.titleMedium),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    value: transparencyPercent.toDouble(),
                    min: 0,
                    max: 100,
                    divisions: 20,
                    label: '$transparencyPercent%',
                    onChanged: (value) => setState(() => _opacity = 1 - (value / 100)),
                  ),
                ),
                SizedBox(width: 48, child: Text('$transparencyPercent%', textAlign: TextAlign.end)),
              ],
            ),
            const SizedBox(height: 8),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.of(context).pop(_opacity),
                child: const Text('Apply'),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

