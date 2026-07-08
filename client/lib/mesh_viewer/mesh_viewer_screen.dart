/// "View Complex Mesh" - an on-device-only viewer for photogrammetry-scale
/// STL/OBJ/glTF files (millions of triangles, hundreds of MB), reached
/// without ever connecting to a server (see `connection_screen.dart`'s entry
/// button). Unlike `PartScreen`'s `ImportFeature` pipeline (which round-trips
/// a file through the backend to build a real/triangulation-only OCCT
/// `TopoDS_Shape` so it can live in the Feature/Body graph), this is a
/// read-only viewer with no Feature history, no Boolean-op ambitions, and no
/// OCCT dependency at all - see `mesh_data.dart`'s own top-of-file doc
/// comment for why that means it never needs the network round-trip (or its
/// 15s timeout) in the first place.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../viewport3d/orbit_camera.dart';
import '../viewport3d/scene_controls_panel.dart';
import '../viewport3d/scene_preferences.dart';
import '../viewport3d/triad.dart';
import '../viewport3d/view_preferences.dart';
import 'mesh_data.dart';
import 'mesh_viewer_render.dart';

class MeshViewerScreen extends StatefulWidget {
  const MeshViewerScreen({super.key});

  @override
  State<MeshViewerScreen> createState() => _MeshViewerScreenState();
}

enum _LoadStage { idle, decoding, buildingMaterial, ready }

class _DecodeRequest {
  final Uint8List bytes;
  final String extension;
  const _DecodeRequest(this.bytes, this.extension);
}

/// Runs off the main isolate via [compute] - decode alone can be a
/// multi-second, main-thread-blocking operation for a large photogrammetry
/// file. `maxTriangles: kMaxViewerTriangles` decimates *during* decode (see
/// `mesh_data.dart`'s own doc comment on `decodeStl`) rather than fully
/// decoding then shrinking afterward - a real on-device crash-to-home-screen
/// on a very large `.glb` confirmed the old "decode everything, decimate
/// after" approach could exhaust memory before decimation ever got a chance
/// to run. Only the already-bounded result ever has to cross back over the
/// isolate boundary either way.
(DecodedMesh mesh, int originalTriangleCount) _decodeAndDecimate(_DecodeRequest request) {
  final mesh = switch (request.extension) {
    'stl' => decodeStl(request.bytes, maxTriangles: kMaxViewerTriangles),
    'obj' => decodeObj(String.fromCharCodes(request.bytes), maxTriangles: kMaxViewerTriangles),
    'gltf' || 'glb' => decodeGltf(request.bytes, maxTriangles: kMaxViewerTriangles),
    _ => throw MeshImportError('Unsupported file extension: ${request.extension}'),
  };
  return (mesh, mesh.sourceTriangleCount);
}

class _MeshViewerScreenState extends State<MeshViewerScreen> {
  _LoadStage _stage = _LoadStage.idle;
  String? _error;
  DecodedMesh? _mesh;
  int? _originalTriangleCount;
  String? _fileName;

  /// Scene/material appearance controls - shared with the main Part viewport
  /// via [ViewPreferences]/[ScenePreferences] (see `scene_preferences.dart`'s
  /// own doc comment for why base colour reuses [ViewPreferences] rather than
  /// a separate field), loaded in [initState] below.
  String _bodyColourHex = ViewPreferences.defaultBodyColourHex;
  double _roughness = ScenePreferences.defaultRoughness;
  double _lightIntensity = ScenePreferences.defaultLightIntensity;
  double _emissiveIntensity = ScenePreferences.defaultEmissiveIntensity;

  /// "Facets" (filled faces) and "Mesh" (wireframe overlay) View-menu
  /// toggles - session-only (not persisted), defaulting to this viewer's
  /// pre-existing behaviour (facets on, no wireframe). See
  /// [buildMeshViewerWireframeNode]'s own doc comment for why wireframe is
  /// unavailable above [kMaxWireframeTriangles].
  bool _showFacets = true;
  bool _showWireframe = false;

  static const _supportedExtensions = ['stl', 'obj', 'gltf', 'glb'];

  @override
  void initState() {
    super.initState();
    _loadScenePrefs();
  }

  /// Mirrors `PartScreen._loadViewPreferences`'s own "don't block the first
  /// frame on a shared_preferences read" pattern - not awaited from
  /// [initState].
  Future<void> _loadScenePrefs() async {
    await ViewPreferences.load();
    await ScenePreferences.load();
    if (!mounted) return;
    setState(() {
      _bodyColourHex = ViewPreferences.bodyColourHex;
      _roughness = ScenePreferences.roughness;
      _lightIntensity = ScenePreferences.lightIntensity;
      _emissiveIntensity = ScenePreferences.emissiveIntensity;
    });
  }

  /// Applied both when the Scene sheet changes a value live and once right
  /// after a new mesh's material is built, so a file picked *after* the user
  /// already dialed in a look doesn't reset to plain white/defaults - unlike
  /// `PartViewport` (which rebuilds a fresh material every `_syncMeshNode`
  /// call), this viewer holds one long-lived [PhysicallyBasedMaterial]
  /// instance per loaded mesh and mutates its fields directly, since nothing
  /// else about the Node/geometry needs to change when only the material's
  /// appearance does.
  void _applyMaterialParams() {
    final material = _material;
    if (material == null) return;
    final hasTexture = _mesh?.textureBytes != null;
    material
      ..baseColorFactor = hasTexture ? vm.Vector4(1, 1, 1, 1) : vector4FromHex(_bodyColourHex)
      ..roughnessFactor = _roughness
      ..metallicFactor = ScenePreferences.fixedMetallic
      ..emissiveFactor = vm.Vector4(_emissiveIntensity, _emissiveIntensity, _emissiveIntensity, 1);
  }

  Future<void> _onBaseColourChanged(String hex) async {
    setState(() {
      _bodyColourHex = hex;
      _applyMaterialParams();
    });
    await ViewPreferences.setBodyColourHex(hex);
  }

  Future<void> _onRoughnessChanged(double value) async {
    setState(() {
      _roughness = value;
      _applyMaterialParams();
    });
    await ScenePreferences.setRoughness(value);
  }

  Future<void> _onLightIntensityChanged(double value) async {
    setState(() => _lightIntensity = value);
    await ScenePreferences.setLightIntensity(value);
  }

  Future<void> _onEmissiveIntensityChanged(double value) async {
    setState(() {
      _emissiveIntensity = value;
      _applyMaterialParams();
    });
    await ScenePreferences.setEmissiveIntensity(value);
  }

  void _openScenePanel() {
    showScenePrefsSheet(
      context,
      baseColourHex: _bodyColourHex,
      onBaseColourChanged: _onBaseColourChanged,
      roughness: _roughness,
      onRoughnessChanged: _onRoughnessChanged,
      lightIntensity: _lightIntensity,
      onLightIntensityChanged: _onLightIntensityChanged,
      emissiveIntensity: _emissiveIntensity,
      onEmissiveIntensityChanged: _onEmissiveIntensityChanged,
    );
  }

  /// `FileType.custom` + `allowedExtensions` was greying out everything but
  /// `.stl` on-device - Android's SAF file-picker filters by MIME type, and
  /// none of these four extensions map to a standard registered MIME type,
  /// so `file_picker`'s extension-to-MIME lookup only reliably enables the
  /// first one. `FileType.any` shows every file (nothing greyed out), and
  /// the extension is validated after picking instead - `_decodeAndDecimate`
  /// already rejects an unsupported one with a clear `MeshImportError`, so
  /// this trades a slightly less curated OS picker dialog for actually being
  /// able to select the other three formats at all.
  Future<void> _pickAndLoad() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any, withData: true);
    if (result == null || result.files.single.bytes == null) return;
    final file = result.files.single;
    final extension = (file.extension ?? '').toLowerCase();
    if (!_supportedExtensions.contains(extension)) {
      setState(() => _error = 'Unsupported file type ".$extension" - pick an STL, OBJ, glTF, or GLB file.');
      return;
    }

    setState(() {
      _stage = _LoadStage.decoding;
      _error = null;
      _mesh = null;
      _fileName = file.name;
    });

    try {
      final (decoded, originalTriangleCount) =
          await compute(_decodeAndDecimate, _DecodeRequest(file.bytes!, extension));
      if (!mounted) return;
      setState(() => _stage = _LoadStage.buildingMaterial);
      final material = await buildMeshViewerMaterial(
        decoded,
        baseColourHex: _bodyColourHex,
        roughness: _roughness,
        emissiveIntensity: _emissiveIntensity,
        fixedMetallic: ScenePreferences.fixedMetallic,
      );
      if (!mounted) return;
      setState(() {
        _mesh = decoded;
        _originalTriangleCount = originalTriangleCount;
        _stage = _LoadStage.ready;
        _material = material;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _LoadStage.idle;
        _error = 'Could not load "${file.name}": $error';
      });
    }
  }

  PhysicallyBasedMaterial? _material;

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _LoadStage.decoding || _stage == _LoadStage.buildingMaterial;
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName == null ? 'View Complex Mesh' : _fileName!),
        actions: [
          // File > Open, File > Exit - this viewer has no Document/Part
          // model to save, so "File" here is just navigation, unlike
          // PartToolbar's much larger File menu.
          PopupMenuButton<String>(
            tooltip: 'File',
            icon: const Icon(Icons.folder_outlined),
            onSelected: (value) {
              if (value == 'open') _pickAndLoad();
              if (value == 'exit') Navigator.of(context).pop();
            },
            itemBuilder: (context) => [
              PopupMenuItem(
                value: 'open',
                enabled: !busy,
                child: const ListTile(leading: Icon(Icons.folder_open), title: Text('Open')),
              ),
              const PopupMenuItem(
                value: 'exit',
                child: ListTile(leading: Icon(Icons.close), title: Text('Exit')),
              ),
            ],
          ),
          // View > Scene, Facets, Mesh - a full ExpansionTile-based View menu
          // (mirroring PartToolbar's) would be overkill for this few entries.
          PopupMenuButton<String>(
            tooltip: 'View',
            icon: const Icon(Icons.visibility_outlined),
            onSelected: (value) {
              switch (value) {
                case 'scene':
                  _openScenePanel();
                  break;
                case 'facets':
                  setState(() => _showFacets = !_showFacets);
                  break;
                case 'wireframe':
                  setState(() => _showWireframe = !_showWireframe);
                  break;
              }
            },
            itemBuilder: (context) {
              final mesh = _mesh;
              final wireframeAvailable = mesh != null && mesh.triangleCount <= kMaxWireframeTriangles;
              return [
                const PopupMenuItem(
                  value: 'scene',
                  child: ListTile(leading: Icon(Icons.wb_incandescent_outlined), title: Text('Scene')),
                ),
                const PopupMenuDivider(),
                CheckedPopupMenuItem(
                  value: 'facets',
                  checked: _showFacets,
                  child: const Text('Facets'),
                ),
                CheckedPopupMenuItem(
                  value: 'wireframe',
                  enabled: wireframeAvailable,
                  checked: _showWireframe && wireframeAvailable,
                  child: Text(wireframeAvailable ? 'Mesh' : 'Mesh (too many triangles)'),
                ),
              ];
            },
          ),
        ],
      ),
      body: _buildBody(context),
    );
  }

  Widget _buildBody(BuildContext context) {
    switch (_stage) {
      case _LoadStage.idle:
        return Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Text(
                  'View an STL, OBJ, or glTF/GLB file entirely on this device - no server '
                  'connection needed. Large photogrammetry-scale meshes are automatically '
                  'decimated to a triangle budget this device can render smoothly.',
                  textAlign: TextAlign.center,
                ),
                const SizedBox(height: 16),
                if (_error != null) ...[
                  Text(_error!, style: TextStyle(color: Theme.of(context).colorScheme.error)),
                  const SizedBox(height: 16),
                ],
                FilledButton.icon(
                  onPressed: _pickAndLoad,
                  icon: const Icon(Icons.folder_open),
                  label: const Text('Pick a mesh file'),
                ),
              ],
            ),
          ),
        );
      case _LoadStage.decoding:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Decoding mesh…'),
            ],
          ),
        );
      case _LoadStage.buildingMaterial:
        return const Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircularProgressIndicator(),
              SizedBox(height: 16),
              Text('Preparing texture…'),
            ],
          ),
        );
      case _LoadStage.ready:
        final mesh = _mesh!;
        final material = _material!;
        return Stack(
          children: [
            Positioned.fill(
              child: _MeshViewerViewport(
                mesh: mesh,
                material: material,
                lightIntensity: _lightIntensity,
                showFacets: _showFacets,
                showWireframe: _showWireframe && mesh.triangleCount <= kMaxWireframeTriangles,
              ),
            ),
            if (_originalTriangleCount != null && _originalTriangleCount != mesh.triangleCount)
              Positioned(
                top: 8,
                left: 8,
                child: _InfoBanner(
                  text: 'Showing ${mesh.triangleCount} of $_originalTriangleCount triangles',
                ),
              ),
          ],
        );
    }
  }
}

class _InfoBanner extends StatelessWidget {
  final String text;
  const _InfoBanner({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.6),
        borderRadius: BorderRadius.circular(6),
      ),
      child: Text(text, style: const TextStyle(color: Colors.white, fontSize: 12)),
    );
  }
}

/// A minimal, standalone orbit-camera viewport for one [DecodedMesh] - the
/// same [OrbitCamera]/gesture-handling pattern `PartViewport` uses, stripped
/// of everything this viewer doesn't need (selection modes, reference
/// planes, Sketch overlays, hit-testing). Not reusing `PartViewport` itself:
/// that widget is built entirely around `MeshDto`/`BodyMeshDto` (the backend's
/// wire format) and the Feature/Body selection model, neither of which apply
/// to a single client-decoded mesh with no server behind it at all.
class _MeshViewerViewport extends StatefulWidget {
  final DecodedMesh mesh;
  final PhysicallyBasedMaterial material;

  /// The "mid lighting" control (see `ScenePreferences`) - drives the
  /// Scene-wide directional light, reapplied whenever it changes (see
  /// [_MeshViewerViewportState.didUpdateWidget]), same controlled-widget
  /// convention `PartViewport.lightIntensity` uses.
  final double lightIntensity;

  /// View menu's "Facets"/"Mesh" toggles - whether the filled-face batches
  /// ([buildMeshViewerNodes]) and/or the wireframe overlay
  /// ([buildMeshViewerWireframeNode]) are currently in the [Scene]. The
  /// caller (`mesh_viewer_screen.dart`) has already clamped [showWireframe]
  /// to false above [kMaxWireframeTriangles] - this widget doesn't
  /// re-check that itself.
  final bool showFacets;
  final bool showWireframe;

  const _MeshViewerViewport({
    required this.mesh,
    required this.material,
    required this.lightIntensity,
    required this.showFacets,
    required this.showWireframe,
  });

  @override
  State<_MeshViewerViewport> createState() => _MeshViewerViewportState();
}

class _MeshViewerViewportState extends State<_MeshViewerViewport> {
  final OrbitCamera _camera = OrbitCamera();
  Scene? _scene;
  String? _error;
  final Map<int, Offset> _activeTouches = {};

  List<Node> _faceNodes = const [];
  Node? _wireframeNode;
  bool _facesInScene = false;
  bool _wireframeInScene = false;

  @override
  void initState() {
    super.initState();
    ensureSceneResourcesLoaded().then((_) {
      if (!mounted) return;
      setState(() {
        _scene = Scene();
        applySceneLighting(_scene!, widget.lightIntensity);
        _faceNodes = buildMeshViewerNodes(widget.mesh, widget.material);
        _syncFacetsAndWireframe();
        final bounds = _boundsOf(widget.mesh);
        _camera.setTarget(bounds.center);
        _camera.setZoomBoundsForRadius(bounds.radius);
      });
    }).catchError((Object error) {
      if (!mounted) return;
      setState(() => _error = error.toString());
    });
  }

  /// Adds/removes [_faceNodes]/[_wireframeNode] to/from [_scene] to match
  /// [widget.showFacets]/[widget.showWireframe] - only touches the [Scene]
  /// on an actual transition (tracked via [_facesInScene]/
  /// [_wireframeInScene]), never re-adding an already-present [Node]. The
  /// wireframe [Node] itself is built lazily, once, the first time it's
  /// needed - a mesh the user never toggles wireframe on for never pays
  /// [buildMeshViewerWireframeNode]'s cost at all.
  void _syncFacetsAndWireframe() {
    final scene = _scene;
    if (scene == null) return;
    if (widget.showFacets != _facesInScene) {
      for (final node in _faceNodes) {
        if (widget.showFacets) {
          scene.add(node);
        } else {
          scene.remove(node);
        }
      }
      _facesInScene = widget.showFacets;
    }
    if (widget.showWireframe != _wireframeInScene) {
      _wireframeNode ??= buildMeshViewerWireframeNode(widget.mesh);
      if (widget.showWireframe) {
        scene.add(_wireframeNode!);
      } else {
        scene.remove(_wireframeNode!);
      }
      _wireframeInScene = widget.showWireframe;
    }
  }

  @override
  void didUpdateWidget(covariant _MeshViewerViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lightIntensity != oldWidget.lightIntensity) {
      final scene = _scene;
      if (scene != null) setState(() => applySceneLighting(scene, widget.lightIntensity));
    }
    if (widget.showFacets != oldWidget.showFacets || widget.showWireframe != oldWidget.showWireframe) {
      setState(_syncFacetsAndWireframe);
    }
  }

  ({vm.Vector3 center, double radius}) _boundsOf(DecodedMesh mesh) {
    final positions = mesh.positions;
    if (positions.isEmpty) return (center: vm.Vector3.zero(), radius: 0);
    var min = vm.Vector3(positions[0], positions[1], positions[2]);
    var max = min.clone();
    for (var i = 0; i < positions.length; i += 3) {
      final p = vm.Vector3(positions[i], positions[i + 1], positions[i + 2]);
      min = vm.Vector3(math.min(min.x, p.x), math.min(min.y, p.y), math.min(min.z, p.z));
      max = vm.Vector3(math.max(max.x, p.x), math.max(max.y, p.y), math.max(max.z, p.z));
    }
    return (center: (min + max) * 0.5, radius: (max - min).length * 0.5);
  }

  void _handlePointerDown(PointerDownEvent event) {
    if (event.kind == PointerDeviceKind.mouse) return;
    _activeTouches[event.pointer] = event.localPosition;
  }

  void _handlePointerMove(PointerMoveEvent event) {
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
    final before = Map<int, Offset>.from(_activeTouches);
    _activeTouches[event.pointer] = event.localPosition;
    _applyPinchPan(before, _activeTouches);
  }

  void _handlePointerEnd(PointerEvent event) {
    if (event.kind != PointerDeviceKind.mouse) _activeTouches.remove(event.pointer);
  }

  void _handlePointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) {
      final scaleFactor = event.scrollDelta.dy > 0 ? 1.1 : 1 / 1.1;
      setState(() => _camera.zoomByFactor(scaleFactor));
    }
  }

  void _applyPinchPan(Map<int, Offset> before, Map<int, Offset> after) {
    Offset centroid(Iterable<Offset> points) =>
        points.reduce((a, b) => a + b) / points.length.toDouble();
    double spread(Iterable<Offset> points, Offset c) =>
        points.isEmpty ? 0 : points.map((p) => (p - c).distance).reduce((a, b) => a + b) / points.length;

    final beforeCentroid = centroid(before.values);
    final afterCentroid = centroid(after.values);
    final beforeSpread = spread(before.values, beforeCentroid);
    final afterSpread = spread(after.values, afterCentroid);
    final panDelta = afterCentroid - beforeCentroid;
    setState(() {
      _camera.panByScreenDelta(panDelta.dx, panDelta.dy);
      if (beforeSpread > 1e-6) _camera.zoomByFactor(beforeSpread / afterSpread);
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    if (error != null) {
      return Center(child: Text('Could not start the 3D viewport: $error'));
    }
    final scene = _scene;
    if (scene == null) return const Center(child: CircularProgressIndicator());
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = Size(constraints.maxWidth, constraints.maxHeight);
        return Listener(
          onPointerDown: _handlePointerDown,
          onPointerMove: _handlePointerMove,
          onPointerUp: _handlePointerEnd,
          onPointerCancel: _handlePointerEnd,
          onPointerSignal: _handlePointerSignal,
          child: CustomPaint(
            size: size,
            painter: _ViewerScenePainter(scene: scene, camera: _camera, size: size),
          ),
        );
      },
    );
  }
}

class _ViewerScenePainter extends CustomPainter {
  final Scene scene;
  final OrbitCamera camera;
  final Size size;

  const _ViewerScenePainter({required this.scene, required this.camera, required this.size});

  static const double _triadMargin = 44;

  @override
  void paint(Canvas canvas, Size canvasSize) {
    canvas.drawRect(Offset.zero & canvasSize, Paint()..color = const Color(0xFF1E1E2E));
    final perspectiveCamera = camera.cameraFor(size);
    scene.render(perspectiveCamera, canvas, viewport: Offset.zero & canvasSize);
    final triadCenter = Offset(_triadMargin, canvasSize.height - _triadMargin);
    paintTriad(canvas, triadCenter, triadAxes(perspectiveCamera));
  }

  @override
  bool shouldRepaint(covariant _ViewerScenePainter oldDelegate) => true;
}
