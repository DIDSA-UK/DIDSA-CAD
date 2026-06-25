import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../api/document_api_client.dart';
import 'mesh_geometry.dart';
import 'orbit_camera.dart';
import 'reference_planes.dart';
import 'render_mode.dart';
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
  /// nudged outward from the mesh's bounding-sphere center first (see
  /// [nudgeSegmentsOutward]), the closest available substitute for a GPU
  /// depth bias to keep them from z-fighting against the filled faces
  /// underneath; `wireframe` mode has no faces to fight, so it skips that.
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
      final bounds = boundsOfMesh(mesh);
      segments = nudgeSegmentsOutward(
        segments,
        bounds?.center ?? vm.Vector3.zero(),
        meshEdgeNudgeAmount,
      );
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
              onPointerDown: _handlePointerDown,
              onPointerMove: _handlePointerMove,
              onPointerUp: _handlePointerEnd,
              onPointerCancel: _handlePointerEnd,
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
          ],
        );
      },
    );
  }
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
