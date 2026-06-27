import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart';
import 'orbit_camera.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
import 'selection_hit_test.dart';
import 'sketch_geometry_3d.dart';
import 'triad.dart';
import 'view_preferences.dart';

/// The Stage 7 3D viewport: renders [mesh] (the placeholder Part mesh from
/// `/document/parts/{id}/mesh`) via `flutter_scene`'s default Unlit
/// material - no custom shaders, wireframes, or cross-sections, per the
/// project brief. Orbit/pan/zoom gestures mirror [SketchCanvas]'s
/// mouse-vs-touch handling: left-drag/single-finger-drag orbits,
/// right-drag/two-finger-drag pans, scroll wheel/pinch zooms.
///
/// Also renders the three fixed reference planes (see [ReferencePlaneKind])
/// and an orientation triad, and turns a tap (as opposed to a drag - see
/// [_tapTravelThreshold]) into a [ReferencePlaneKind] hit-test: [onPlaneTap]
/// fires for a tap that lands on a rendered plane rectangle, [onBackgroundTap]
/// for one that doesn't. [selectedPlane] only affects which plane (if any) is
/// drawn brighter - [PartScreen] owns the actual selection state, the same
/// controlled-widget pattern [FeatureTreePanel] already uses for
/// [selectedFeatureId].
class PartViewport extends StatefulWidget {
  final MeshDto? mesh;
  final ReferencePlaneKind? selectedPlane;
  final void Function(ReferencePlaneKind plane) onPlaneTap;
  final VoidCallback onBackgroundTap;

  /// Per-Feature 3D Sketch geometry (Lines/Circles already projected onto
  /// their plane, see [SketchGeometry3D]), keyed by Feature id - callers
  /// should omit hidden Features' entries entirely rather than passing
  /// [SketchGeometry3D.empty], and should only build a new `Map` instance
  /// when the content actually changes (see [didUpdateWidget]), since a new
  /// instance triggers a full GPU geometry rebuild of every entry.
  final Map<String, SketchGeometry3D> sketchGeometries;

  /// True while [mesh] is an Extrude live preview (see [PartScreen]'s
  /// debounced create/update-then-refetch flow) rather than confirmed
  /// geometry - renders the mesh translucent and tinted so a preview solid
  /// is never mistaken for the Part's actual, saved shape.
  final bool isPreviewMesh;

  /// Stage 10b: globally hides all three reference planes - both their
  /// rendered geometry and their [onPlaneTap] hit-testing, so a tap where a
  /// hidden plane would be falls through to [onBackgroundTap] instead of
  /// silently selecting an invisible target. [PartScreen] owns the toggle
  /// (via [PartToolbar]'s "Hide/Show Reference Planes" entry), the same
  /// controlled-widget pattern [selectedPlane] already uses.
  final bool referencePlanesHidden;

  /// Stage 11: which of [ViewportRenderMode]'s three display modes is
  /// currently active - controls whether [mesh]'s filled faces are drawn at
  /// all ([ViewportRenderMode.showsFilledFaces]) and whether its real OCCT
  /// edge polylines are drawn on top ([ViewportRenderMode.showsEdges]).
  /// [PartScreen] owns this, the same controlled-widget pattern
  /// [referencePlanesHidden] already uses.
  final ViewportRenderMode renderMode;

  /// Stage 18: the 3D viewport's appearance preferences (see
  /// [ViewPreferences]) - [PartScreen] owns these, the same controlled-
  /// widget pattern [renderMode] already uses. [bgColourHex] repaints the
  /// canvas background every frame (see [_ScenePainter.paint]); [bodyColourHex]/
  /// [bodyOpacity] only take effect on the next [_syncMeshNode] rebuild
  /// (see [didUpdateWidget]), since they're baked into [_meshNode]'s
  /// material rather than read per-frame.
  final String bgColourHex;
  final String bodyColourHex;
  final double bodyOpacity;

  /// Stage 23: true while the viewport is in selection mode (as opposed to
  /// the default orbit mode) - [PartScreen] owns the toggle. Per Item 7 of
  /// the brief, this only ever gates the *new* cursor/hover/selection
  /// dispatch added below; it never alters what the existing orbit gesture
  /// handlers (`_handlePointerDown`/`_handlePointerMove`/`_handlePointerEnd`)
  /// do.
  final bool selectionMode;

  /// The currently-selected entities (Item 4/5) - [PartScreen] owns this set
  /// and decides add/remove-toggle semantics in [onSelectionToggle]; this
  /// widget only renders it (see [_syncSelectedEntityNodes]).
  final Set<SelectionEntityRef> selectedEntities;

  /// Fired when the Select button commits a non-empty hover hit - the
  /// caller (see [PartScreen]) decides whether this adds or removes the
  /// entity from [selectedEntities] (Item 4's toggle rule).
  final void Function(SelectionEntityRef entity)? onSelectionToggle;

  /// Fired when the Select button commits while the cursor is over empty
  /// space - Item 4's "clears entire selection set" rule.
  final VoidCallback? onClearSelection;

  const PartViewport({
    super.key,
    required this.mesh,
    required this.selectedPlane,
    required this.onPlaneTap,
    required this.onBackgroundTap,
    this.sketchGeometries = const {},
    this.isPreviewMesh = false,
    this.referencePlanesHidden = false,
    this.renderMode = ViewportRenderMode.shaded,
    this.bgColourHex = ViewPreferences.defaultBgColourHex,
    this.bodyColourHex = ViewPreferences.defaultBodyColourHex,
    this.bodyOpacity = ViewPreferences.defaultBodyOpacity,
    this.selectionMode = false,
    this.selectedEntities = const {},
    this.onSelectionToggle,
    this.onClearSelection,
  });

  @override
  State<PartViewport> createState() => PartViewportState();
}

class PartViewportState extends State<PartViewport> with TickerProviderStateMixin {
  final OrbitCamera _camera = OrbitCamera();

  /// Null until `flutter_scene`'s static resources (shaders, default
  /// textures) finish loading - [Scene.render] silently skips frames before
  /// that, so nothing is built until this is non-null.
  Scene? _scene;
  Node? _meshNode;

  /// Stage 11: the Part mesh's real OCCT edge polylines, rendered separately
  /// from [_meshNode]'s filled faces - present whenever
  /// [PartViewport.renderMode] has [ViewportRenderModeX.showsEdges] set,
  /// regardless of whether the faces themselves are also showing.
  Node? _edgesNode;
  Map<ReferencePlaneKind, Node> _planeNodes = {};
  Map<String, Node> _sketchNodes = {};

  /// Set if GPU/scene setup throws - without this, that failure would only
  /// ever reach the console (it happens inside an unawaited Future), leaving
  /// [build] stuck showing its loading spinner forever with no way for
  /// anyone looking at the screen to tell something went wrong.
  String? _error;

  /// Live touch pointers by id, for pinch-zoom/two-finger-pan - same
  /// approach as [SketchCanvas]'s `_activeTouches`.
  final Map<int, Offset> _activeTouches = {};

  /// The viewport's current size, refreshed every build - needed by
  /// [_handleTap] to build a [PerspectiveCamera.screenPointToRay] ray, which
  /// only ever runs later, from a pointer-up callback that has no [Size] of
  /// its own.
  Size _viewportSize = Size.zero;

  /// Cumulative pointer travel (pixels) since the current gesture's first
  /// pointer-down - mirrors [SketchCanvas]'s `_singleTouchTravel`, used the
  /// same way to tell a tap (plane selection) apart from an orbit/pan drag.
  double _gestureTravel = 0;

  /// Set once a second touch has joined the current gesture, so the tail end
  /// of a pinch (fingers lifting one by one) is never mistaken for a tap.
  bool _hadMultiTouch = false;

  static const double _tapTravelThreshold = 10.0;

  /// See the Select button's [Positioned.bottom] comment in [build] -
  /// clearance above Items 5/6's bottom panel/drawer when something is
  /// selected.
  static const double _kSelectButtonRaisedBottom = 232.0;

  /// Stage 23 Item 2: the cursor's current screen position while
  /// [PartViewport.selectionMode] is true - null whenever selection mode is
  /// off (so the crosshair overlay/Select button in [build] hide entirely)
  /// or before the first `didUpdateWidget` entry into selection mode has had
  /// a chance to set it to the viewport centre.
  Offset? _cursorPosition;

  /// Stage 23 Item 3: the nearest face/edge/vertex to [_cursorPosition],
  /// recomputed every time the cursor moves - null if nothing in
  /// [PartViewport.mesh] is within hit range and the cursor isn't over any
  /// face either.
  HoverHit? _hoverHit;

  /// How far (logical pixels) a single pointer-move event's `delta` moves
  /// [_cursorPosition] - less than 1:1 per Item 2's "sensitivity-scaled, not
  /// 1:1" requirement, so a full-viewport drag doesn't blow straight past
  /// the model.
  static const double _cursorDragSensitivity = 0.6;

  Node? _hoverNode;
  Node? _selectedFacesNode;
  Node? _selectedEdgesNode;
  Node? _selectedVerticesNode;

  static final vm.Vector4 _hoverColor = vector4FromHex('#FFC107', opacity: 0.55);
  static final vm.Vector4 _selectedColor = vector4FromHex('#2196F3', opacity: 0.85);

  @override
  void initState() {
    super.initState();
    debugPrint('[PartViewport] Scene.initializeStaticResources()...');
    Scene.initializeStaticResources().then((_) {
      debugPrint('[PartViewport] Scene.initializeStaticResources() done');
      if (!mounted) return;
      setState(() {
        _scene = Scene();
        _syncMeshNode();
        _syncEdgesNode();
        _syncReferencePlaneNodes();
        _syncSketchNodes();
      });
    }).catchError((Object error) {
      debugPrint('[PartViewport] GPU/scene setup failed: $error');
      if (!mounted) return;
      setState(() => _error = error.toString());
    });
  }

  @override
  void didUpdateWidget(covariant PartViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.mesh != oldWidget.mesh ||
        widget.isPreviewMesh != oldWidget.isPreviewMesh ||
        widget.renderMode != oldWidget.renderMode ||
        widget.bodyColourHex != oldWidget.bodyColourHex ||
        widget.bodyOpacity != oldWidget.bodyOpacity) {
      setState(_syncMeshNode);
    }
    if (widget.mesh != oldWidget.mesh || widget.renderMode != oldWidget.renderMode) {
      setState(_syncEdgesNode);
    }
    if (widget.selectedPlane != oldWidget.selectedPlane ||
        widget.referencePlanesHidden != oldWidget.referencePlanesHidden) {
      setState(_syncReferencePlaneNodes);
    }
    if (widget.sketchGeometries != oldWidget.sketchGeometries) {
      setState(_syncSketchNodes);
    }
    if (widget.selectionMode != oldWidget.selectionMode) {
      setState(() {
        if (widget.selectionMode) {
          // Item 2: "re-entering resets to viewport centre".
          _cursorPosition = _viewportCenter();
          _recomputeHover();
        } else {
          // Item 1/2: leaving selection mode "removes cursor".
          _cursorPosition = null;
          _hoverHit = null;
        }
        _syncHoverNode();
      });
    }
    if (widget.selectedEntities != oldWidget.selectedEntities) {
      setState(_syncSelectedEntityNodes);
    }
    if (widget.mesh != oldWidget.mesh && widget.selectionMode) {
      // The mesh's entity ids are only stable within one response (see
      // MeshDto's doc comments) - a hover/selection computed against the
      // old mesh could point at ids that no longer exist, so both are
      // recomputed/resynced from the new mesh too.
      setState(() {
        _recomputeHover();
        _syncHoverNode();
        _syncSelectedEntityNodes();
      });
    }
  }

  void _syncMeshNode() {
    final scene = _scene;
    if (scene == null) return;
    if (_meshNode != null) {
      scene.remove(_meshNode!);
      _meshNode = null;
    }
    final mesh = widget.mesh;
    if (mesh == null) {
      debugPrint('[PartViewport] _syncMeshNode: no mesh yet');
      return;
    }
    if (mesh.vertices.isEmpty) {
      // flutter_scene's UnskinnedGeometry.uploadVertexData allocates a GPU
      // device buffer sized off the vertex/index data - a zero-length
      // buffer (e.g. every body hidden, or a Cut with nothing to cut from)
      // throws "DeviceBuffer creation failed" rather than just rendering
      // nothing, so skip building a Node entirely in that case (mirrors
      // what boundsOfMesh returning null would feed the camera below, were
      // there a Node to compute bounds from).
      debugPrint('[PartViewport] _syncMeshNode: mesh has no vertices, skipping geometry');
      _camera.setTarget(vm.Vector3.zero());
      _camera.setZoomBoundsForRadius(0);
      return;
    }
    // Stage 11: in wireframe mode, the filled-faces Node is skipped
    // entirely (only the edges Node built by _syncEdgesNode is shown) - but
    // the camera target/zoom bounds below are still derived from the real
    // mesh data either way, so switching modes never moves the camera.
    if (widget.renderMode.showsFilledFaces) {
      debugPrint('[PartViewport] _syncMeshNode: geometryFromMesh(${mesh.vertices.length} verts)...');
      final geometry = geometryFromMesh(mesh);
      debugPrint('[PartViewport] _syncMeshNode: geometryFromMesh done, adding Node to Scene...');
      final material = widget.isPreviewMesh
          ? (UnlitMaterial()
            ..alphaMode = AlphaMode.blend
            ..baseColorFactor = vm.Vector4(1.0, 0.65, 0.0, 0.45))
          // TODO: flutter_scene's UnlitMaterial has no roughness/metallic (or
          // any other lit-shading) parameter to give the body a "subtle
          // specular highlight"/matte-metallic finish per the brief -
          // revisit if/when a PBR material type ships.
          : (UnlitMaterial()
            ..alphaMode = widget.bodyOpacity < 1.0 ? AlphaMode.blend : AlphaMode.opaque
            ..baseColorFactor = vector4FromHex(widget.bodyColourHex, opacity: widget.bodyOpacity));
      final node = Node(mesh: Mesh(geometry, material));
      scene.add(node);
      _meshNode = node;
      debugPrint('[PartViewport] _syncMeshNode: Node added to Scene');
    }
    final bounds = boundsOfMesh(mesh);
    _camera.setTarget(bounds?.center ?? vm.Vector3.zero());
    _camera.setZoomBoundsForRadius(bounds?.boundingSphereRadius ?? 0);
  }

  /// Stage 11: rebuilds [_edgesNode] from [PartViewport.mesh]'s real OCCT
  /// edge polylines (see [edgeSegmentsFromMesh]) whenever
  /// [ViewportRenderModeX.showsEdges] is set - independent of whether the
  /// filled-faces Node above is also present, since `wireframe` mode shows
  /// edges with no faces at all. In `shadedWithEdges` mode the segments are
  /// nudged outward from the mesh's bounding-sphere center (see
  /// [nudgeSegmentsOutward]), the closest available substitute for a GPU
  /// depth bias to keep them from z-fighting against the filled faces
  /// underneath; `wireframe` mode has no faces to fight, so it skips this.
  void _syncEdgesNode() {
    final scene = _scene;
    if (scene == null) return;
    if (_edgesNode != null) {
      scene.remove(_edgesNode!);
      _edgesNode = null;
    }
    final mesh = widget.mesh;
    if (mesh == null || !widget.renderMode.showsEdges) return;
    var segments = edgeSegmentsFromMesh(mesh);
    if (segments.isEmpty) return;
    if (widget.renderMode == ViewportRenderMode.shadedWithEdges) {
      final center = boundsOfMesh(mesh)?.center ?? vm.Vector3.zero();
      segments = nudgeSegmentsOutward(segments, center, meshEdgeNudgeAmount);
    }
    final node = buildMeshEdgesNode(segments, color: widget.renderMode.edgeColor);
    scene.add(node);
    _edgesNode = node;
  }

  /// Rebuilds all three reference-plane nodes from scratch - cheap enough
  /// (three small rectangles) to redo wholesale on every selection change,
  /// rather than reaching into [UnlitMaterial] to mutate an existing node's
  /// tint in place.
  void _syncReferencePlaneNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _planeNodes.values) {
      scene.remove(node);
    }
    if (widget.referencePlanesHidden) {
      _planeNodes = {};
      return;
    }
    _planeNodes = {
      for (final plane in ReferencePlaneKind.values)
        plane: buildReferencePlaneNode(plane, selected: plane == widget.selectedPlane),
    };
    for (final node in _planeNodes.values) {
      scene.add(node);
    }
  }

  /// Mirrors [_syncReferencePlaneNodes]: rebuilds every Sketch's geometry
  /// node from scratch from [PartViewport.sketchGeometries] - relies on the
  /// widget's own contract (see its doc comment) that a new `Map` instance
  /// only arrives when content genuinely changed, so this never runs more
  /// often than that.
  void _syncSketchNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in _sketchNodes.values) {
      scene.remove(node);
    }
    _sketchNodes = {
      for (final entry in widget.sketchGeometries.entries)
        if (!entry.value.isEmpty) entry.key: buildSketchGeometryNode(entry.key, entry.value),
    };
    for (final node in _sketchNodes.values) {
      scene.add(node);
    }
  }

  /// Animates the camera to look straight down at [plane], per the brief's
  /// camera-animation-into-Sketch feature - smoothly interpolating
  /// [OrbitCamera.orientation] via quaternion `slerp` (never Euler angles, so
  /// there's no risk of gimbal-lock artifacts mid-animation) over
  /// [duration]. Callers (see `PartScreen`) await this and only navigate to
  /// the 2D canvas once it completes.
  ///
  /// 400ms with [Curves.easeInOut] is this implementation's own judgment
  /// call, within the brief's specified 300-500ms range - worth confirming
  /// on a real device that it doesn't feel too slow/fast.
  ///
  /// Needs [TickerProviderStateMixin], not [SingleTickerProviderStateMixin]:
  /// this is called once per "enter a Sketch" action over this State's
  /// whole lifetime, and `SingleTickerProviderStateMixin` only permits
  /// `createTicker` to succeed once ever (even after the prior
  /// `AnimationController` is disposed) - every call past the first would
  /// throw on `AnimationController(vsync: this, ...)` below, silently
  /// rejecting this method's Future before `_openSketch` ever runs.
  Future<void> animateToPlane(
    ReferencePlaneKind plane, {
    Duration duration = const Duration(milliseconds: 400),
  }) async {
    final from = _camera.orientation;
    final to = orientationFacingPlane(plane);
    final controller = AnimationController(vsync: this, duration: duration);
    final curved = CurvedAnimation(parent: controller, curve: Curves.easeInOut);
    void tick() {
      if (!mounted) return;
      setState(() => _camera.orientation = from.slerp(to, curved.value));
    }

    controller.addListener(tick);
    try {
      await controller.forward();
    } finally {
      controller.removeListener(tick);
      controller.dispose();
    }
  }

  void _handlePointerDown(PointerDownEvent event) {
    _gestureTravel = 0;
    if (event.kind == PointerDeviceKind.mouse) return;
    _activeTouches[event.pointer] = event.localPosition;
    _hadMultiTouch = _activeTouches.length > 1;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    _gestureTravel += event.delta.distance;
    if (event.kind == PointerDeviceKind.mouse) {
      if (event.buttons & kPrimaryMouseButton != 0) {
        setState(() => _camera.orbitByScreenDelta(event.delta.dx, event.delta.dy));
      } else if (event.buttons & kSecondaryMouseButton != 0) {
        setState(() => _camera.panByScreenDelta(event.delta.dx, event.delta.dy));
      }
      return;
    }

    if (_activeTouches.length < 2) {
      setState(() => _camera.orbitByScreenDelta(event.delta.dx, event.delta.dy));
      return;
    }

    _hadMultiTouch = true;
    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches);
  }

  void _handlePointerEnd(PointerEvent event) {
    final wasTap = event is PointerUpEvent && !_hadMultiTouch && _gestureTravel < _tapTravelThreshold;
    if (event.kind != PointerDeviceKind.mouse) {
      _activeTouches.remove(event.pointer);
      if (_activeTouches.isEmpty) _hadMultiTouch = false;
    }
    if (wasTap) {
      _handleTap(event.localPosition);
    }
  }

  /// Converts a confirmed tap into a [ReferencePlaneKind] hit-test, via the
  /// same [PerspectiveCamera.screenPointToRay] `flutter_scene` already
  /// builds for its own picking/`raycast.dart` - reused here rather than
  /// reimplementing screen-to-world unprojection by hand.
  void _handleTap(Offset localPosition) {
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(localPosition, _viewportSize);
    final hit = widget.referencePlanesHidden ? null : hitTestReferencePlanes(ray);
    if (hit != null) {
      widget.onPlaneTap(hit.plane);
    } else {
      widget.onBackgroundTap();
    }
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      // Scrolling "down" (positive dy) zooms out - same convention as
      // SketchCanvas, but inverted in effect since a bigger `distance`
      // (unlike a bigger sketch `zoom`) means further away/more zoomed out.
      final scaleFactor = event.scrollDelta.dy > 0 ? 1.1 : 1 / 1.1;
      setState(() => _camera.zoomByFactor(scaleFactor));
    }
  }

  void _applyPinchPan(Map<int, Offset> before, Map<int, Offset> after) {
    final beforeCentroid = _centroidOf(before.values);
    final afterCentroid = _centroidOf(after.values);
    final beforeSpread = _averageSpread(before.values, beforeCentroid);
    final afterSpread = _averageSpread(after.values, afterCentroid);
    final panDelta = afterCentroid - beforeCentroid;

    setState(() {
      _camera.panByScreenDelta(panDelta.dx, panDelta.dy);
      if (beforeSpread > 1e-6) {
        _camera.zoomByFactor(beforeSpread / afterSpread);
      }
    });
  }

  Offset _centroidOf(Iterable<Offset> points) {
    var sum = Offset.zero;
    for (final point in points) {
      sum += point;
    }
    return sum / points.length.toDouble();
  }

  double _averageSpread(Iterable<Offset> points, Offset centroid) {
    if (points.length < 2) return 0;
    var total = 0.0;
    for (final point in points) {
      total += (point - centroid).distance;
    }
    return total / points.length;
  }

  // --- Stage 23 Items 2/3: selection-mode cursor/hover dispatch -----------
  //
  // Everything below is purely additive on top of the existing
  // orbit/pan/zoom/tap gesture handlers above - none of those methods are
  // modified by a single line, per Item 7's "do not touch the existing
  // orbit logic in any way". These wrappers only decide, per pointer event,
  // whether to forward to the existing orbit handler (selection mode off)
  // or to the new selection-mode cursor logic (selection mode on); orbit
  // mode's own behaviour is unreachable from here.

  Offset _viewportCenter() => Offset(_viewportSize.width / 2, _viewportSize.height / 2);

  void _onPointerDown(PointerDownEvent event) {
    if (widget.selectionMode) return; // Item 2: no tap-gesture detection.
    _handlePointerDown(event);
  }

  void _onPointerMove(PointerMoveEvent event) {
    if (!widget.selectionMode) {
      _handlePointerMove(event);
      return;
    }
    if (event.kind == PointerDeviceKind.mouse) {
      _handleSelectionPointerHover(event.localPosition);
    } else {
      _handleSelectionPointerMove(event.delta);
    }
  }

  void _onPointerEnd(PointerEvent event) {
    if (widget.selectionMode) return; // Item 2: no tap-gesture detection.
    _handlePointerEnd(event);
  }

  void _onPointerHover(PointerHoverEvent event) {
    if (!widget.selectionMode) return; // No orbit-mode hover handling exists.
    _handleSelectionPointerHover(event.localPosition);
  }

  /// Item 2: "Drag moves cursor relatively (sensitivity-scaled, not 1:1);
  /// lifting/re-touching doesn't jump cursor" - reusing Flutter's own
  /// per-event [delta] (rather than tracking a touch-start position the way
  /// the orbit handlers do) means a finger lifting and a different finger
  /// touching back down never causes a jump, since neither event carries a
  /// delta of its own.
  void _handleSelectionPointerMove(Offset delta) {
    final current = _cursorPosition ?? _viewportCenter();
    setState(() {
      _cursorPosition = _clampToViewport(current + delta * _cursorDragSensitivity);
      _recomputeHover();
      _syncHoverNode();
    });
  }

  /// Item 2: "Desktop mouse move drives cursor" - absolute, not delta-based,
  /// since a real mouse's position is meaningful on its own.
  void _handleSelectionPointerHover(Offset localPosition) {
    setState(() {
      _cursorPosition = _clampToViewport(localPosition);
      _recomputeHover();
      _syncHoverNode();
    });
  }

  Offset _clampToViewport(Offset position) {
    if (_viewportSize.isEmpty) return position;
    return Offset(
      position.dx.clamp(0.0, _viewportSize.width),
      position.dy.clamp(0.0, _viewportSize.height),
    );
  }

  /// Item 3's hover hit-test, run from [_cursorPosition] - null result
  /// clears any prior hover (cursor moved over empty background).
  void _recomputeHover() {
    final mesh = widget.mesh;
    final cursor = _cursorPosition;
    if (mesh == null || cursor == null) {
      _hoverHit = null;
      return;
    }
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(cursor, _viewportSize);
    _hoverHit = hitTestMeshEntities(ray: ray, viewportSize: _viewportSize, mesh: mesh);
  }

  /// The Select button's `onPressed` (Item 4): commits the current hover (if
  /// any) as a toggle, or clears the whole selection set if the cursor is
  /// over empty space - [PartScreen] (which owns the actual selection set)
  /// decides add-vs-remove via [PartViewport.onSelectionToggle].
  void _commitSelection() {
    final hit = _hoverHit;
    if (hit == null) {
      widget.onClearSelection?.call();
    } else {
      widget.onSelectionToggle?.call(hit.entity);
    }
  }

  /// Rebuilds [_hoverNode] from [_hoverHit] - one of vertex/edge/face
  /// highlight geometry depending on [_hoverHit]'s kind (Item 3: "hovered
  /// face = subtle tint; hovered edge = colour change + thickness increase;
  /// hovered vertex = small filled circle").
  void _syncHoverNode() {
    final scene = _scene;
    if (scene == null) return;
    if (_hoverNode != null) {
      scene.remove(_hoverNode!);
      _hoverNode = null;
    }
    final mesh = widget.mesh;
    final hit = _hoverHit;
    if (mesh == null || hit == null) return;
    final node = _buildEntityHighlightNode(mesh, hit.entity, _hoverColor);
    if (node == null) return;
    scene.add(node);
    _hoverNode = node;
  }

  /// Rebuilds all three selected-entity highlight nodes (one per kind, each
  /// combining every currently-selected entity of that kind) from
  /// [PartViewport.selectedEntities] - Item 3: "selected entities = distinct
  /// 'selected' colour (not just hover colour)".
  void _syncSelectedEntityNodes() {
    final scene = _scene;
    if (scene == null) return;
    for (final node in [_selectedFacesNode, _selectedEdgesNode, _selectedVerticesNode]) {
      if (node != null) scene.remove(node);
    }
    _selectedFacesNode = null;
    _selectedEdgesNode = null;
    _selectedVerticesNode = null;
    final mesh = widget.mesh;
    if (mesh == null) return;

    final faceTriangles = <(vm.Vector3, vm.Vector3, vm.Vector3)>[];
    final edgeSegments = <(vm.Vector3, vm.Vector3)>[];
    final vertexPositions = <vm.Vector3>[];
    for (final entity in widget.selectedEntities) {
      switch (entity.kind) {
        case SelectionEntityKind.face:
          faceTriangles.addAll(faceTrianglesForId(mesh, entity.id));
        case SelectionEntityKind.edge:
          edgeSegments.addAll(edgeSegmentsForId(mesh, entity.id));
        case SelectionEntityKind.vertex:
          final position = vertexPositionForId(mesh, entity.id);
          if (position != null) vertexPositions.add(position);
      }
    }

    if (faceTriangles.isNotEmpty) {
      final node = buildHighlightFacesNode(faceTriangles, color: _selectedColor);
      scene.add(node);
      _selectedFacesNode = node;
    }
    if (edgeSegments.isNotEmpty) {
      final node = buildMeshEdgesNode(
        edgeSegments,
        color: _selectedColor,
        width: kHighlightEdgeStrokeWidth,
      );
      scene.add(node);
      _selectedEdgesNode = node;
    }
    if (vertexPositions.isNotEmpty) {
      final node = buildVertexMarkersNode(vertexPositions, color: _selectedColor);
      scene.add(node);
      _selectedVerticesNode = node;
    }
  }

  /// Resolves one [SelectionEntityRef] (any kind) into its highlight [Node],
  /// shared by [_syncHoverNode] - a single entity's worth of whichever of
  /// [buildHighlightFacesNode]/[buildMeshEdgesNode]/[buildVertexMarkersNode]
  /// matches its kind, or null if that id no longer exists in [mesh].
  Node? _buildEntityHighlightNode(MeshDto mesh, SelectionEntityRef entity, vm.Vector4 color) {
    switch (entity.kind) {
      case SelectionEntityKind.face:
        final triangles = faceTrianglesForId(mesh, entity.id);
        if (triangles.isEmpty) return null;
        return buildHighlightFacesNode(triangles, color: color);
      case SelectionEntityKind.edge:
        final segments = edgeSegmentsForId(mesh, entity.id);
        if (segments.isEmpty) return null;
        return buildMeshEdgesNode(segments, color: color, width: kHighlightEdgeStrokeWidth);
      case SelectionEntityKind.vertex:
        final position = vertexPositionForId(mesh, entity.id);
        if (position == null) return null;
        return buildVertexMarkersNode([position], color: color);
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Text(
            'Could not start the 3D viewport: $error',
            style: TextStyle(color: Theme.of(context).colorScheme.error),
            textAlign: TextAlign.center,
          ),
        ),
      );
    }
    final scene = _scene;
    if (scene == null) {
      return const Center(child: CircularProgressIndicator());
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        _viewportSize = size;
        return Stack(
          children: [
            Listener(
              onPointerDown: _onPointerDown,
              onPointerMove: _onPointerMove,
              onPointerUp: _onPointerEnd,
              onPointerCancel: _onPointerEnd,
              onPointerHover: _onPointerHover,
              onPointerSignal: _handlePointerSignal,
              child: CustomPaint(
                size: size,
                painter: _ScenePainter(
                  scene: scene,
                  camera: _camera,
                  size: size,
                  backgroundColor: colorFromHex(widget.bgColourHex),
                  polylineCarryingNodes: [
                    ..._planeNodes.values,
                    ..._sketchNodes.values,
                    if (_edgesNode != null) _edgesNode!,
                    if (_hoverNode != null) _hoverNode!,
                    if (_selectedEdgesNode != null) _selectedEdgesNode!,
                    if (_selectedVerticesNode != null) _selectedVerticesNode!,
                  ],
                ),
              ),
            ),
            // top-right, not top-left, so it doesn't collide with
            // PartScreen's feature-tree toolbar toggle button which lives
            // in that corner.
            Positioned(
              top: 8,
              right: 8,
              child: IconButton.filled(
                tooltip: 'Reset view',
                icon: const Icon(Icons.center_focus_strong),
                onPressed: () => setState(_camera.reset),
              ),
            ),
            if (widget.selectionMode && _cursorPosition != null)
              IgnorePointer(
                child: CustomPaint(
                  size: size,
                  painter: _CursorCrosshairPainter(position: _cursorPosition!, hasHover: _hoverHit != null),
                ),
              ),
            if (widget.selectionMode)
              Positioned(
                // Items 5/6's context panel + selection list drawer (see
                // PartScreen) sit at the very bottom of the screen once
                // anything is selected - this button rises clear of them in
                // that case. _kSelectButtonRaisedBottom is a static
                // estimate of their combined height (not a measured
                // layout), since this widget has no visibility into a
                // sibling's actual rendered size.
                bottom: widget.selectedEntities.isEmpty ? 16 : _kSelectButtonRaisedBottom,
                left: 0,
                right: 0,
                child: Center(
                  child: FilledButton.icon(
                    onPressed: _commitSelection,
                    icon: const Icon(Icons.center_focus_weak),
                    label: const Text('Select'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}

/// Stage 23 Item 2: the persistent selection-mode cursor - a simple
/// screen-space crosshair, mirroring [SketchCanvas]'s own cursor look.
/// [hasHover] swaps it to the "selected" colour when something's under it,
/// the same colour [PartViewportState._selectedColor] uses, so the cursor
/// itself previews what the Select button is about to commit.
class _CursorCrosshairPainter extends CustomPainter {
  final Offset position;
  final bool hasHover;

  const _CursorCrosshairPainter({required this.position, required this.hasHover});

  static const double _armLength = 12;

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = hasHover ? const Color(0xFF2196F3) : const Color(0xFFFFFFFF)
      ..strokeWidth = 2;
    canvas.drawLine(
      position - const Offset(_armLength, 0),
      position + const Offset(_armLength, 0),
      paint,
    );
    canvas.drawLine(
      position - const Offset(0, _armLength),
      position + const Offset(0, _armLength),
      paint,
    );
  }

  @override
  bool shouldRepaint(covariant _CursorCrosshairPainter oldDelegate) =>
      oldDelegate.position != position || oldDelegate.hasHover != hasHover;
}

class _ScenePainter extends CustomPainter {
  final Scene scene;
  final OrbitCamera camera;
  final Size size;
  final Color backgroundColor;

  /// Every [Node] (reference planes, Sketch geometry) whose [Mesh] may
  /// contain a [PolylineGeometry] primitive - each such primitive's
  /// camera-facing strip must be rebuilt via `updateForCamera` every frame
  /// before [Scene.render], per [PolylineGeometry]'s own contract.
  final List<Node> polylineCarryingNodes;

  /// `paint` runs every frame, so this guards [paint]'s diagnostic logging to
  /// fire only once - the first call already proves `scene.render` (the
  /// flutter_scene GPU call) didn't hang, which is all the logging is for.
  static bool _loggedFirstPaint = false;

  _ScenePainter({
    required this.scene,
    required this.camera,
    required this.size,
    required this.backgroundColor,
    this.polylineCarryingNodes = const [],
  });

  /// Distance of the triad's center from each edge of the viewport - large
  /// enough that its arms (see [paintTriad]'s `armLength`) and axis labels
  /// never clip against the corner.
  static const double _triadMargin = 44;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    final isFirstPaint = !_loggedFirstPaint;
    if (isFirstPaint) {
      _loggedFirstPaint = true;
      debugPrint('[PartViewport] _ScenePainter.paint: first frame, calling scene.render()...');
    }
    canvas.drawRect(Offset.zero & canvasSize, Paint()..color = backgroundColor);
    final perspectiveCamera = camera.cameraFor(size);
    for (final node in polylineCarryingNodes) {
      for (final primitive in node.mesh?.primitives ?? const []) {
        final geometry = primitive.geometry;
        if (geometry is PolylineGeometry) {
          geometry.updateForCamera(perspectiveCamera, canvasSize);
        }
      }
    }
    scene.render(perspectiveCamera, canvas, viewport: Offset.zero & canvasSize);
    if (isFirstPaint) {
      debugPrint('[PartViewport] _ScenePainter.paint: first frame, scene.render() returned');
    }
    // Bottom-left, per the project brief's own stated preference - drawn
    // last so it stays on top of the rendered scene.
    final triadCenter = Offset(_triadMargin, canvasSize.height - _triadMargin);
    paintTriad(canvas, triadCenter, triadAxes(perspectiveCamera));
  }

  @override
  bool shouldRepaint(covariant _ScenePainter oldDelegate) => true;
}
