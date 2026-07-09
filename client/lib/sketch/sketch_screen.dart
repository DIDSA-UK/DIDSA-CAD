import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../api/document_api_client.dart' show BodyMeshDto;
import '../api/sketch_api_client.dart' show CircleDto, LineDto, PointDto;
import '../didsa_logo_button.dart';
import '../viewport3d/part_viewport.dart';
import '../viewport3d/reference_planes.dart';
import '../viewport3d/render_mode.dart';
import '../viewport3d/sketch_geometry_3d.dart';
import '../viewport3d/view_prefs_sheets.dart';
import '../viewport3d/view_preferences.dart';
import 'sketch_canvas.dart';
import 'sketch_construction_method_bar.dart';
import 'sketch_controller.dart';
import 'sketch_dimension_bar.dart';
import 'sketch_ribbon.dart';
import 'sketch_speed_dial.dart';

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

  const SketchScreen({
    super.key,
    this.controller,
    this.adoptSketchId,
    this.referenceGhostSegments = const [],
    this.bodies = const [],
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

  /// On-device feedback: Orbit View needs the same View controls the main 3D
  /// viewport offers (render mode, body colour, body transparency) - see
  /// [_build3DViewMenu]. All session-only, same as the 2D canvas's own view
  /// preferences above; [_orbitRenderMode] defaults to `shadedWithEdges`
  /// (also on-device feedback: edges should be visible by default here) and
  /// [_orbitBodyOpacity] defaults to 4.1's "~25% transparent" ask - overriding
  /// [ViewPreferences.defaultBodyOpacity]'s `1.0` rather than reusing the
  /// Part viewport's own persisted preference.
  ViewportRenderMode _orbitRenderMode = ViewportRenderMode.shadedWithEdges;
  String _orbitBodyColourHex = ViewPreferences.defaultBodyColourHex;
  double _orbitBodyOpacity = 0.75;

  @override
  void initState() {
    super.initState();
    _controller = widget.controller ?? SketchController();
    final adoptSketchId = widget.adoptSketchId;
    if (adoptSketchId != null) {
      _controller.adoptSketch(adoptSketchId);
    } else {
      _controller.ensureSketch();
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
                return Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: Icon(
                    _controller.isUnderConstrained ? Icons.lock_open : Icons.lock,
                    size: 18,
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
              icon: const Icon(Icons.undo),
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
                icon: const Icon(Icons.select_all),
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
                  _buildBaseLayer(),
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
                            child: const Icon(Icons.logout),
                          ),
                          if (widget.referenceGhostSegments.isNotEmpty) ...[
                            const SizedBox(height: 8),
                            FloatingActionButton.small(
                              heroTag: 'reference-body-visibility-fab',
                              tooltip:
                                  _referenceBodyHidden ? 'Show Reference Body' : 'Hide Reference Body',
                              onPressed: () => setState(() => _referenceBodyHidden = !_referenceBodyHidden),
                              child: Icon(_referenceBodyHidden ? Icons.visibility_off : Icons.visibility),
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
                              if (referencePlaneKindFromApiValue(_controller.plane) == null) {
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
                                  onPressed: () => setState(() => _orbitViewActive = !_orbitViewActive),
                                  child: const Icon(Icons.view_in_ar),
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
                        child: const Icon(Icons.menu),
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
                            child: const Icon(Icons.restore),
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
                          child: const Icon(Icons.open_with),
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

  /// Phase 4.1/4.2: the Stack's base layer - the flat 2D [SketchCanvas]
  /// normally, or (while [_orbitViewActive]) a read-only, look-only 3D
  /// [PartViewport] embedding [widget.bodies] (shaded, at
  /// [_orbitBodyOpacity]) alongside this Sketch's own geometry, reusing
  /// `viewport3d/sketch_geometry_3d.dart`'s existing projection - "so the
  /// user can see where they are sketching" relative to the real part, per
  /// the brief. Editing always stays on the 2D canvas (see the scope doc's
  /// "Decided: look-only toggle" note) - `onPlaneTap`/`onBackgroundTap` are
  /// no-ops and `selectionMode` stays false, so orbiting is the only
  /// interaction available here.
  Widget _buildBaseLayer() {
    final planeKind = referencePlaneKindFromApiValue(_controller.plane);
    if (_orbitViewActive && planeKind != null) {
      return AnimatedBuilder(
        animation: _controller,
        builder: (context, _) => PartViewport(
          key: _orbitViewportKey,
          bodies: widget.bodies,
          selectedPlane: null,
          onPlaneTap: (_) {},
          onBackgroundTap: () {},
          sketchGeometries: {
            (_controller.sketchId ?? 'active-sketch'): sketchGeometry3DFrom(
              basis: SketchPlaneBasis.fixed(planeKind),
              points: _pointDtosFrom(_controller),
              lines: _lineDtosFrom(_controller),
              circles: _circleDtosFrom(_controller),
            ),
          },
          referencePlanesHidden: true,
          renderMode: _orbitRenderMode,
          bodyColourHex: _orbitBodyColourHex,
          bodyOpacity: _orbitBodyOpacity,
          initialViewPlane: planeKind,
        ),
      );
    }
    return SketchCanvas(
      controller: _controller,
      referenceGhostSegments: widget.referenceGhostSegments,
      referenceBodyHidden: _referenceBodyHidden,
      constraintLabelsVisible: _constraintLabelsVisible,
      canvasColor: _canvasColor,
      canvasOpacity: _canvasOpacity,
    );
  }

  /// The "Return to Default View" FAB's action - re-orients the embedded
  /// [PartViewport]'s camera to look straight at the Sketch's own plane,
  /// animated, reusing [PartViewportState.animateToPlane] exactly as the 3D
  /// viewport already does for its camera-into-sketch transition. Stays in
  /// Orbit View rather than exiting it - leaving is the toggle FAB's job.
  void _returnOrbitToDefaultView() {
    final planeKind = referencePlaneKindFromApiValue(_controller.plane);
    if (planeKind == null) return;
    _orbitViewportKey.currentState?.animateToPlane(planeKind);
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
          _build3DViewMenu(context, density, titleStyle)
        else
          ExpansionTile(
            dense: true,
            visualDensity: density,
            leading: const Icon(Icons.visibility_outlined, size: 20),
            title: const Text('View', style: titleStyle),
            initiallyExpanded: true,
            children: [
              SwitchListTile(
                dense: true,
                visualDensity: density,
                title: const Text('Constraint Labels', style: titleStyle),
                value: _constraintLabelsVisible,
                onChanged: (value) => setState(() => _constraintLabelsVisible = value),
              ),
              ListTile(
                dense: true,
                visualDensity: density,
                leading: Icon(Icons.palette_outlined, color: _canvasColor, size: 20),
                title: const Text('Canvas Colour', style: titleStyle),
                onTap: () => _pickCanvasColor(context),
              ),
              ListTile(
                dense: true,
                visualDensity: density,
                leading: const Icon(Icons.opacity_outlined, size: 20),
                title: const Text('Canvas Transparency', style: titleStyle),
                onTap: () => _pickCanvasOpacity(context),
              ),
            ],
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
  Widget _build3DViewMenu(BuildContext context, VisualDensity density, TextStyle titleStyle) {
    return ExpansionTile(
      dense: true,
      visualDensity: density,
      leading: const Icon(Icons.view_in_ar, size: 20),
      title: const Text('3D View', style: titleStyle),
      initiallyExpanded: true,
      children: [
        for (final mode in ViewportRenderMode.values)
          ListTile(
            dense: true,
            visualDensity: density,
            leading: Icon(mode.icon, size: 20),
            title: Text(mode.label, style: titleStyle),
            trailing: mode == _orbitRenderMode ? const Icon(Icons.check, size: 18) : null,
            onTap: () => setState(() => _orbitRenderMode = mode),
          ),
        ListTile(
          dense: true,
          visualDensity: density,
          leading: Icon(Icons.circle, color: colorFromHex(_orbitBodyColourHex), size: 20),
          title: const Text('Body Colour', style: titleStyle),
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
        ListTile(
          dense: true,
          visualDensity: density,
          leading: const Icon(Icons.opacity_outlined, size: 20),
          title: const Text('Body Transparency', style: titleStyle),
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
