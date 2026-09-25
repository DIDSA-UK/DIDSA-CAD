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
library;

import 'dart:async';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_scene/scene.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:vector_math/vector_math.dart' as vm;

import '../viewport3d/orbit_camera.dart';
import '../viewport3d/scene_controls_panel.dart';
import '../viewport3d/scene_preferences.dart';
import '../viewport3d/triad.dart';
import '../viewport3d/view_preferences.dart';
import '../viewport3d/svg_icon.dart';
import 'mesh_data.dart';
import 'mesh_viewer_preferences.dart';
import 'mesh_viewer_render.dart';
import 'step_bindings.dart';
import 'step_loader.dart';

class MeshViewerScreen extends StatefulWidget {
  const MeshViewerScreen({super.key});

  @override
  State<MeshViewerScreen> createState() => _MeshViewerScreenState();
}

enum _LoadStage { idle, decoding, buildingMaterial, ready }

class _DecodeRequest {
  final String path;
  final String extension;
  final int maxTriangles;
  const _DecodeRequest(this.path, this.extension, this.maxTriangles);
}

/// Runs off the main isolate via [compute] - decode alone can be a
/// multi-second, main-thread-blocking operation for a large photogrammetry
/// file. `maxTriangles` (from [MeshViewerPreferences], a user-adjustable
/// setting - see that class's own doc comment) decimates *during* decode
/// (see `mesh_data.dart`'s own doc comment on `decodeStl`) rather than fully
/// decoding then shrinking afterward - a real on-device crash-to-home-screen
/// on a very large `.glb` confirmed the old "decode everything, decimate
/// after" approach could exhaust memory before decimation ever got a chance
/// to run. Only the already-bounded result ever has to cross back over the
/// isolate boundary either way.
///
/// Reads [_DecodeRequest.path] itself (via [File.readAsBytesSync], fine
/// here since this already runs off the main isolate) rather than taking
/// pre-read bytes - a real on-device crash log confirmed the previous
/// "pick with `withData: true`, pass the resulting bytes in" approach was
/// the actual cause of a reported crash: `file_picker` reads the whole file
/// into a Java byte array *and* re-encodes it through a Flutter
/// `MethodChannel`'s `StandardMessageCodec` (a growable `ByteArrayOutputStream`
/// that doubles its buffer as it copies the file's bytes into the platform-
/// channel reply envelope) to hand it to Dart - for a large enough file, that
/// briefly needs roughly *twice* the file's size on Android's default (and
/// fairly small, ~256 MiB) Java heap, well before this app's own Dart-side
/// code ever runs. The actual crash: `java.lang.OutOfMemoryError: Failed to
/// allocate a 150384072 byte allocation ... growth limit 268435456` inside
/// `StandardMessageCodec.writeValue` / `ByteArrayOutputStream.grow`, not
/// anywhere in this app's own decode or texture code. Reading the file by
/// its own path via `dart:io` instead avoids the platform channel (and the
/// Java heap it's bound by) for the file's actual bytes entirely - the
/// picker only ever hands over a short path string.
(DecodedMesh mesh, int originalTriangleCount) _decodeAndDecimate(_DecodeRequest request) {
  final bytes = File(request.path).readAsBytesSync();
  final mesh = switch (request.extension) {
    'stl' => decodeStl(bytes, maxTriangles: request.maxTriangles),
    'obj' => decodeObj(String.fromCharCodes(bytes), maxTriangles: request.maxTriangles),
    'gltf' || 'glb' => decodeGltf(bytes, maxTriangles: request.maxTriangles),
    _ => throw MeshImportError('Unsupported file extension: ${request.extension}'),
  };
  return (mesh, mesh.sourceTriangleCount);
}

/// Runs [applyUpAxis] then [applyMirror] off the main isolate via [compute] -
/// a photogrammetry-scale mesh can still have millions of vertices even
/// after decimation, and this needs to re-run every time the View menu's "Up
/// axis"/"Mirror" toggles change (not just once at load), so it can't assume
/// it's cheap enough for the main thread. Both corrections are combined into
/// one isolate hop (rather than separate [compute] calls) to avoid copying
/// the whole position/normal arrays repeatedly for a single toggle change.
/// Takes a record (rather than each function's own positional parameters)
/// since [compute] only passes a single argument to its isolate entry point.
///
/// **2026-07-22**: no longer runs [applyRenderMirrorCorrection] - on-device
/// feedback (a model rendering mirrored in the Mesh Viewer specifically,
/// right after the Part Modeller's own root-cause camera fix landed) traced
/// straight to this. `applyRenderMirrorCorrection` was built on the same
/// diagnosis `viewport3d/mesh_geometry.dart`'s `renderMirrorCorrectedMesh`
/// was - since disproven and reverted there (see `docs/status.md`'s
/// "the real root cause found" entry): the actual bug was a confirmed,
/// genuine mirror in `flutter_scene`'s own `PerspectiveCamera` view-matrix
/// construction, shared by every viewport in this app, `OrbitCamera`
/// included - fixed once at its root (`FixedPerspectiveCamera`), not by
/// negating any mesh's own data. Running this extra, now-unneeded world-Z
/// negation on top of the now-fixed camera reintroduced exactly the mirror
/// it used to (coincidentally, for whichever camera pose the original
/// diagnosis happened to test at) cancel out. [applyUpAxis]/[applyMirror]
/// are untouched - both were independently validated against real file
/// bytes and a ground-truth Python-rendered comparison, entirely outside
/// this app's own camera/GPU pipeline, so neither was ever entangled with
/// the camera bug.
DecodedMesh _applyCorrectionsIsolate((DecodedMesh, MeshUpAxis, bool) args) =>
    applyMirror(applyUpAxis(args.$1, args.$2), args.$3);

/// Runs the actual [MeshExportFormat.stl]/[MeshExportFormat.glb] byte
/// encoding off the main isolate via [compute] - `encodeMeshAsStl`/
/// `encodeMeshAsGlb` are pure CPU-bound loops over a photogrammetry-scale
/// mesh's whole position/normal/UV arrays, the same "don't block the main
/// thread" reasoning as [_decodeAndDecimate]. Takes the mesh *after*
/// [reencodeMeshTexturesForExport] has already run (that part needs
/// `dart:ui`, which isn't available off the main isolate, so it can't be
/// folded into this same [compute] call - see `_exportMesh`, which does
/// both steps in sequence).
Uint8List _encodeMeshIsolate((DecodedMesh, MeshExportFormat) args) =>
    args.$2 == MeshExportFormat.stl ? encodeMeshAsStl(args.$1) : encodeMeshAsGlb(args.$1);

class _MeshViewerScreenState extends State<MeshViewerScreen> {
  _LoadStage _stage = _LoadStage.idle;
  String? _error;

  /// True only while [_exportMesh] is running - a separate flag rather than
  /// another [_LoadStage] value, since exporting happens *after* the mesh is
  /// already [_LoadStage.ready], not instead of it.
  bool _exporting = false;

  /// The raw decode result, exactly as [decodeStl]/[decodeObj]/[decodeGltf]
  /// produced it - never mutated. [_mesh] (below) is always derived from
  /// this by applying [_upAxis]/[_mirror], so toggling either View menu
  /// choice can re-derive a fresh [_mesh] without re-picking/re-decoding the
  /// file.
  DecodedMesh? _rawMesh;

  /// [_rawMesh] with [_upAxis] and [_mirror] applied - what's actually
  /// rendered/queried for triangle counts and material info (unaffected by
  /// either choice, carried straight through by [applyUpAxis]/[applyMirror]).
  DecodedMesh? _mesh;
  int? _originalTriangleCount;
  String? _fileName;

  /// View menu's "Up axis" toggle - see `mesh_data.dart`'s own doc comment
  /// on [MeshUpAxis]/[applyUpAxis] for why this needs to be a manual
  /// per-file choice. Seeded from [MeshViewerPreferences.upAxis] (the
  /// device/pipeline-wide default, set from the mesh viewer settings
  /// screen) in [_loadScenePrefs], and itself written back there on every
  /// change - so the last file you corrected becomes the new default for
  /// the next one, the same "live change also persists" convention
  /// [ScenePreferences]'s own sliders already use.
  MeshUpAxis _upAxis = MeshViewerPreferences.defaultUpAxis;

  /// View menu's "Mirror" toggle - see `mesh_data.dart`'s own doc comment on
  /// [applyMirror] for the real file (a Blender-exported drone
  /// photogrammetry scan) confirmed to need this. Same
  /// seed-from-/persist-to-[MeshViewerPreferences] convention as [_upAxis].
  bool _mirror = MeshViewerPreferences.defaultMirror;

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

  /// Every non-STEP mesh format this viewer has always understood - STEP
  /// support (see below) is additive, gated on whether the native OCCT
  /// wrapper actually loaded on this build/device.
  static const _baseSupportedExtensions = ['stl', 'obj', 'gltf', 'glb'];

  /// Cached once at [initState] (a `DynamicLibrary.open` attempt - not free
  /// to repeat on every rebuild) - see `step_loader.dart`'s own doc comment
  /// on [loadOcctBindingsOrNull] for why this returns `null` rather than
  /// throwing when native STEP support isn't available. `.step`/`.stp` only
  /// ever appear in [_supportedExtensions] when this is non-null.
  StepOcctBindings? _stepBindings;

  List<String> get _supportedExtensions =>
      _stepBindings == null ? _baseSupportedExtensions : [..._baseSupportedExtensions, 'step', 'stp'];

  /// Non-null only for a loaded STEP file - the per-body hide/show/invert/
  /// reset model (see `step_loader.dart`'s own doc comment on
  /// [MultiBodyMesh]). `null` for every other format, and for a STEP file
  /// this viewer's own `_MeshViewerViewport` uses to know whether to build
  /// body-tagged (taggable/hideable) geometry at all.
  MultiBodyMesh? _multiBodyMesh;

  StreamSubscription<StepLoadEvent>? _stepLoadSubscription;
  int _stepBodiesTotal = 0;
  int _stepBodiesLoaded = 0;

  @override
  void initState() {
    super.initState();
    _stepBindings = loadOcctBindingsOrNull();
    _loadScenePrefs();
  }

  @override
  void dispose() {
    _stepLoadSubscription?.cancel();
    super.dispose();
  }

  /// Mirrors `PartScreen._loadViewPreferences`'s own "don't block the first
  /// frame on a shared_preferences read" pattern - not awaited from
  /// [initState].
  Future<void> _loadScenePrefs() async {
    await ViewPreferences.load();
    await ScenePreferences.load();
    await MeshViewerPreferences.load();
    if (!mounted) return;
    setState(() {
      _bodyColourHex = ViewPreferences.bodyColourHex;
      _roughness = ScenePreferences.roughness;
      _lightIntensity = ScenePreferences.lightIntensity;
      _emissiveIntensity = ScenePreferences.emissiveIntensity;
      _upAxis = MeshViewerPreferences.upAxis;
      _mirror = MeshViewerPreferences.mirror;
    });
  }

  /// [applyUpAxis]/[applyMirror]'s combined async, off-main-isolate wrapper -
  /// shared by [_pickAndLoad] (applied once, right after decode),
  /// [_onUpAxisChanged], and [_onMirrorChanged] (re-applied to the same
  /// [_rawMesh] whenever either View menu toggle changes, with no need to
  /// re-pick/re-decode the file).
  Future<DecodedMesh> _applyCorrectionsTo(DecodedMesh rawMesh) =>
      compute(_applyCorrectionsIsolate, (rawMesh, _upAxis, _mirror));

  /// View menu's "Up axis" toggle - see `mesh_data.dart`'s own doc comment
  /// on [MeshUpAxis] for the real-world bug this exists to correct. Rebuilds
  /// [_mesh] from the unchanged [_rawMesh] (no re-decode needed) and lets
  /// `_MeshViewerViewport` notice the new [DecodedMesh] instance and rebuild
  /// its geometry accordingly - the existing [_materials] stay as they are,
  /// since a texture doesn't depend on vertex orientation.
  Future<void> _onUpAxisChanged(MeshUpAxis axis) async {
    setState(() => _upAxis = axis);
    await MeshViewerPreferences.setUpAxis(axis);
    final rawMesh = _rawMesh;
    if (rawMesh == null) return;
    final corrected = await _applyCorrectionsTo(rawMesh);
    if (!mounted || _rawMesh != rawMesh) return;
    setState(() {
      _mesh = corrected;
      // Up-axis/mirror correction preserves triangle order (a pure
      // per-vertex transform - see applyUpAxis/applyMirror), so a STEP
      // file's own per-body startTriangle/triangleCount ranges (computed
      // once at load time) stay valid against the corrected mesh unchanged;
      // only the mesh reference itself needs updating.
      _multiBodyMesh?.mesh = corrected;
    });
  }

  /// View menu's "Mirror" toggle - see `mesh_data.dart`'s own doc comment on
  /// [applyMirror] for the real-world bug this exists to correct. Identical
  /// shape to [_onUpAxisChanged], just toggling the other correction.
  Future<void> _onMirrorChanged(bool mirror) async {
    setState(() => _mirror = mirror);
    await MeshViewerPreferences.setMirror(mirror);
    final rawMesh = _rawMesh;
    if (rawMesh == null) return;
    final corrected = await _applyCorrectionsTo(rawMesh);
    if (!mounted || _rawMesh != rawMesh) return;
    setState(() {
      _mesh = corrected;
      _multiBodyMesh?.mesh = corrected;
    });
  }

  /// Whether `_materials[index]` has its own base-color texture - a real
  /// photogrammetry glTF's per-primitive [DecodedMesh.materialGroups] entry
  /// if present, else (STL/OBJ, or a single-primitive glTF) [_mesh]'s own
  /// top-level [DecodedMesh.textureBytes] for `index == 0`. Drives whether
  /// [_applyMaterialParams] overwrites that material's `baseColorFactor`
  /// with the user's swatch colour (untextured) or leaves it white
  /// (textured - see [buildMeshViewerMaterial]'s own doc comment on why).
  bool _hasTextureForMaterial(int index) {
    final groups = _mesh?.materialGroups;
    if (groups != null && groups.isNotEmpty) return groups[index].textureBytes != null;
    return _mesh?.textureBytes != null;
  }

  /// Applied both when the Scene sheet changes a value live and once right
  /// after a new mesh's materials are built, so a file picked *after* the
  /// user already dialed in a look doesn't reset to plain white/defaults -
  /// unlike `PartViewport` (which rebuilds a fresh material every
  /// `_syncMeshNode` call), this viewer holds one long-lived
  /// [PhysicallyBasedMaterial] instance per material group of the loaded
  /// mesh (see [DecodedMesh.materialGroups]) and mutates each one's fields
  /// directly, since nothing else about the Node/geometry needs to change
  /// when only the materials' appearance does.
  void _applyMaterialParams() {
    final materials = _materials;
    if (materials == null) return;
    for (var i = 0; i < materials.length; i++) {
      final hasTexture = _hasTextureForMaterial(i);
      materials[i]
        ..baseColorFactor = hasTexture ? vm.Vector4(1, 1, 1, 1) : vector4FromHex(_bodyColourHex)
        ..roughnessFactor = _roughness
        ..metallicFactor = ScenePreferences.fixedMetallic
        ..emissiveFactor = vm.Vector4(_emissiveIntensity, _emissiveIntensity, _emissiveIntensity, 1);
    }
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
  ///
  /// Deliberately does *not* pass `withData: true` - a real on-device crash
  /// log confirmed that reading the whole file into memory as
  /// `PlatformFile.bytes` (which `file_picker` does by encoding it through a
  /// Flutter `MethodChannel` reply, on Android's small default Java heap)
  /// was the actual cause of a reported crash-to-home-screen on a large
  /// file - see `_decodeAndDecimate`'s own doc comment for the exact
  /// stack trace. `file.path` instead (file_picker copies content-provider
  /// URIs to a real cache file even without `withData`, so this is reliably
  /// non-null on the Android/iOS/desktop targets this app builds for - no
  /// web target exists in this project) is read directly via `dart:io`
  /// inside [_decodeAndDecimate]'s own background isolate, never crossing
  /// the platform channel at all.
  Future<void> _pickAndLoad() async {
    final result = await FilePicker.platform.pickFiles(type: FileType.any);
    if (result == null) return;
    final file = result.files.single;
    final path = file.path;
    if (path == null) {
      setState(() => _error = 'Could not access "${file.name}" - no local file path was returned.');
      return;
    }
    final extension = (file.extension ?? '').toLowerCase();
    final isStep = extension == 'step' || extension == 'stp';
    if (!_supportedExtensions.contains(extension)) {
      if (isStep) {
        // Distinct from the generic "unsupported extension" message below -
        // this is a *recognized* extension whose native support simply
        // isn't available on this build/device (see `step_loader.dart`'s
        // own `loadOcctBindingsOrNull` doc comment), not an actually
        // unsupported format.
        setState(() => _error =
            'STEP files (.$extension) need native STEP support, which is not available on this build or '
            'device - other formats (STL, OBJ, glTF, GLB) are unaffected.');
      } else {
        setState(() => _error = 'Unsupported file type ".$extension" - pick an STL, OBJ, glTF, or GLB file.');
      }
      return;
    }

    if (isStep) {
      await _loadStepFile(path, file.name);
      return;
    }

    setState(() {
      _stage = _LoadStage.decoding;
      _error = null;
      _rawMesh = null;
      _mesh = null;
      _multiBodyMesh = null;
      _fileName = file.name;
    });

    try {
      final (decoded, originalTriangleCount) = await compute(
        _decodeAndDecimate,
        _DecodeRequest(path, extension, MeshViewerPreferences.maxTriangles),
      );
      final corrected = await _applyCorrectionsTo(decoded);
      if (!mounted) return;
      setState(() => _stage = _LoadStage.buildingMaterial);
      final materials = await buildMeshViewerMaterials(
        corrected,
        baseColourHex: _bodyColourHex,
        roughness: _roughness,
        emissiveIntensity: _emissiveIntensity,
        fixedMetallic: ScenePreferences.fixedMetallic,
      );
      if (!mounted) return;
      setState(() {
        _rawMesh = decoded;
        _mesh = corrected;
        _originalTriangleCount = originalTriangleCount;
        _stage = _LoadStage.ready;
        _materials = materials;
      });
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _stage = _LoadStage.idle;
        _error = 'Could not load "${file.name}": $error';
      });
    }
  }

  /// STEP counterpart of the STL/OBJ/glTF branch above - streams
  /// [loadStepFile]'s events (see that function's own doc comment) rather
  /// than awaiting one `compute()` call, so the viewport shows each body as
  /// soon as it's tessellated instead of waiting for the whole assembly.
  /// [StepLoadAccumulator] owns the running concatenation; every arriving
  /// [StepLoadBodyMeshEvent] produces a brand-new [DecodedMesh] instance
  /// (see that accumulator's own doc comment), which `_MeshViewerViewport`'s
  /// existing "a different DecodedMesh instance -> rebuild geometry" check
  /// (`didUpdateWidget`) already picks up with no extra plumbing needed - the
  /// same mechanism the "Up axis"/"Mirror" toggles already rely on.
  Future<void> _loadStepFile(String path, String fileName) async {
    final bindings = _stepBindings;
    if (bindings == null) {
      setState(() => _error = 'STEP support is not available on this build/device.');
      return;
    }

    setState(() {
      _stage = _LoadStage.decoding;
      _error = null;
      _rawMesh = null;
      _mesh = null;
      _multiBodyMesh = null;
      _materials = null;
      _fileName = fileName;
      _stepBodiesTotal = 0;
      _stepBodiesLoaded = 0;
    });

    final accumulator = StepLoadAccumulator();
    final completer = Completer<void>();

    await _stepLoadSubscription?.cancel();
    _stepLoadSubscription = loadStepFile(
      path,
      maxTriangles: MeshViewerPreferences.maxTriangles,
      quality: MeshViewerPreferences.stepTessellationQuality,
    ).listen(
      (event) => _handleStepLoadEvent(event, accumulator, fileName, completer),
      onError: (Object error) {
        if (!mounted) return;
        setState(() {
          _stage = _LoadStage.idle;
          _error = 'Could not load "$fileName": $error';
        });
        if (!completer.isCompleted) completer.complete();
      },
      onDone: () {
        if (!completer.isCompleted) completer.complete();
      },
    );

    await completer.future;
  }

  Future<void> _handleStepLoadEvent(
    StepLoadEvent event,
    StepLoadAccumulator accumulator,
    String fileName,
    Completer<void> completer,
  ) async {
    switch (event) {
      case StepLoadBodiesEvent():
        accumulator.addBodies(event.bodies);
        if (!mounted) return;
        setState(() => _stepBodiesTotal = event.bodies.length);
      case StepLoadBodyMeshEvent():
        accumulator.addBodyMesh(event.bodyIndex, event.positions, event.normals);
        final multi = accumulator.toMultiBodyMesh();
        if (!mounted) return;
        setState(() {
          _stepBodiesLoaded++;
          _rawMesh = multi.mesh;
          _mesh = multi.mesh;
          _multiBodyMesh = multi;
        });
        if (_materials == null) {
          // Built once, off the first body that produces any geometry at
          // all - a STEP body has no texture concept (unlike a glTF
          // materialGroup), so this is always a single, flat-tint material
          // shared by every body, same as the STL/OBJ case.
          setState(() => _stage = _LoadStage.buildingMaterial);
          final materials = await buildMeshViewerMaterials(
            multi.mesh,
            baseColourHex: _bodyColourHex,
            roughness: _roughness,
            emissiveIntensity: _emissiveIntensity,
            fixedMetallic: ScenePreferences.fixedMetallic,
          );
          if (!mounted) return;
          setState(() {
            _materials = materials;
            _stage = _LoadStage.ready;
          });
        }
      case StepLoadErrorEvent():
        if (!mounted) return;
        setState(() => _error = _error == null ? event.message : '$_error\n${event.message}');
      case StepLoadDoneEvent():
        if (!mounted) return;
        final multi = _multiBodyMesh;
        if (multi == null || multi.mesh.triangleCount == 0) {
          setState(() {
            _stage = _LoadStage.idle;
            _error ??= 'Could not load "$fileName": no usable geometry was produced.';
          });
        }
        if (!completer.isCompleted) completer.complete();
    }
  }

  /// "Invert visibility" button - flips every body's [MeshBody.visible]
  /// flag. `_MeshViewerViewport` reconciles its own Scene Nodes against the
  /// new flags on its next `didUpdateWidget` (see that widget's own
  /// `_reconcileBodyNodes`) - no explicit Scene mutation needed here.
  void _invertBodyVisibility() {
    final multi = _multiBodyMesh;
    if (multi == null) return;
    setState(multi.invertVisibility);
  }

  /// "Reset visibility" button - see [_invertBodyVisibility]'s own doc
  /// comment for why no explicit Scene mutation is needed here either.
  void _resetBodyVisibility() {
    final multi = _multiBodyMesh;
    if (multi == null) return;
    setState(multi.resetVisibility);
  }

  /// Tap-to-hide's own callback from `_MeshViewerViewport` (see that
  /// widget's own ray-hit-testing doc comment) - hides the tapped body.
  void _handleBodyTapped(int bodyId) {
    final multi = _multiBodyMesh;
    if (multi == null || bodyId < 0 || bodyId >= multi.bodies.length) return;
    // MeshBody.id is always its own index into MultiBodyMesh.bodies (see
    // step_loader.dart's StepLoadAccumulator) - a direct index is exact and
    // avoids depending on package:collection just for firstOrNull.
    final body = multi.bodies[bodyId];
    setState(() => body.visible = false);
  }

  /// The body list/legend - a checkbox-per-body bottom sheet, a reasonable
  /// complement to tap-to-hide for a body too small/hidden-behind-others to
  /// reliably tap (see this feature's own plan doc). Uses a
  /// [StatefulBuilder] so ticking a checkbox updates the sheet's own
  /// checkmark immediately, alongside the real [MeshBody.visible] mutation
  /// and the outer screen's `setState` that lets `_MeshViewerViewport`
  /// reconcile its Scene.
  void _showBodyListSheet() {
    final multi = _multiBodyMesh;
    if (multi == null) return;
    showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) {
        return StatefulBuilder(
          builder: (sheetContext, setSheetState) {
            return SafeArea(
              child: ListView(
                shrinkWrap: true,
                children: [
                  const Padding(
                    padding: EdgeInsets.all(16),
                    child: Text('Bodies', style: TextStyle(fontWeight: FontWeight.bold)),
                  ),
                  for (final body in multi.bodies)
                    CheckboxListTile(
                      value: body.visible,
                      title: Text(body.name),
                      subtitle: Text('${body.triangleCount} triangles'),
                      onChanged: (value) {
                        setSheetState(() => body.visible = value ?? true);
                        setState(() {});
                      },
                    ),
                ],
              ),
            );
          },
        );
      },
    );
  }

  /// The mesh viewer's "Export" feature - saves the *decimated, corrected*
  /// mesh currently on screen ([_mesh]: post-decimation, post-Up-axis,
  /// post-Mirror) as a real, much smaller file, based on whatever the
  /// current decimation-triangle-budget/texture settings already reduced it
  /// to - rather than only ever being able to *view* a reduced version
  /// without ever keeping one.
  ///
  /// [MeshExportFormat.glb] first re-encodes every material's texture down
  /// to the same resolution this viewer already displays it at
  /// ([reencodeMeshTexturesForExport] - needs `dart:ui`, so it has to run
  /// here on the main isolate, *before* the actual byte encoding). The
  /// (already texture-reduced) mesh is then handed to [_encodeMeshIsolate]
  /// via [compute] - pure CPU-bound work over the whole mesh, same
  /// off-main-isolate reasoning as [_decodeAndDecimate].
  ///
  /// Writes the encoded bytes to a real file via `dart:io` in this app's own
  /// temporary directory (`path_provider`'s `getTemporaryDirectory()` - no
  /// storage permission needed, since it's this app's own sandbox), then
  /// hands the resulting *file path* to `share_plus`'s `Share.shareXFiles`
  /// so the OS share sheet lets the user save/send it anywhere they like.
  ///
  /// Deliberately does **not** use `FilePicker.platform.saveFile(bytes:
  /// ...)` (an earlier version of this method did) - confirmed on-device to
  /// fail silently for a heavily-textured, "very large" source file. This
  /// viewer explicitly targets photogrammetry-scale meshes (the default
  /// `maxTriangles` budget alone is 3,000,000 - at ~32 bytes/vertex that's
  /// already ~275 MiB of geometry before a single texture byte is counted),
  /// so "the decimated result is always small enough for the platform
  /// channel" - the assumption the `saveFile` version made - turned out to
  /// be wrong for the same reason `_pickAndLoad`'s original `withData: true`
  /// was: on Android, `saveFile`'s own `bytes` parameter still has to cross
  /// into native code as a `StandardMessageCodec`-encoded `MethodChannel`
  /// argument, bound by the same small Java heap. A local `dart:io` write
  /// followed by a share-sheet handoff of just the *path* avoids that
  /// entirely, in either direction, regardless of how large the export is.
  Future<void> _exportMesh(MeshExportFormat format) async {
    final mesh = _mesh;
    if (mesh == null) return;
    setState(() => _exporting = true);
    try {
      final meshForExport = format == MeshExportFormat.glb ? await reencodeMeshTexturesForExport(mesh) : mesh;
      final bytes = await compute(_encodeMeshIsolate, (meshForExport, format));
      final extension = format == MeshExportFormat.stl ? 'stl' : 'glb';
      final baseName = _fileName == null ? 'mesh_export' : _stripFileExtension(_fileName!);
      final tempDir = await getTemporaryDirectory();
      final exportPath = '${tempDir.path}/$baseName-reduced.$extension';
      await File(exportPath).writeAsBytes(bytes);
      if (!mounted) return;
      await Share.shareXFiles([XFile(exportPath)], subject: 'DIDSA-CAD mesh export');
    } catch (error) {
      if (!mounted) return;
      setState(() => _error = 'Could not export mesh: $error');
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  static String _stripFileExtension(String name) {
    final dot = name.lastIndexOf('.');
    return dot <= 0 ? name : name.substring(0, dot);
  }

  List<PhysicallyBasedMaterial>? _materials;

  @override
  Widget build(BuildContext context) {
    final busy = _stage == _LoadStage.decoding || _stage == _LoadStage.buildingMaterial || _exporting;
    return Scaffold(
      appBar: AppBar(
        title: Text(_fileName == null ? 'View Complex Mesh' : _fileName!),
        actions: [
          // File > Open, Export as GLB/STL, Exit - this viewer has no
          // Document/Part model to save (a native "Save" doesn't apply
          // here), so "Export" is really "write out the currently-decimated
          // mesh as a real, much smaller file" rather than PartToolbar's
          // much larger File menu's save/load story.
          PopupMenuButton<String>(
            tooltip: 'File',
            icon: const Icon(Icons.folder_outlined),
            onSelected: (value) {
              switch (value) {
                case 'open':
                  _pickAndLoad();
                  break;
                case 'export-glb':
                  _exportMesh(MeshExportFormat.glb);
                  break;
                case 'export-stl':
                  _exportMesh(MeshExportFormat.stl);
                  break;
                case 'exit':
                  Navigator.of(context).pop();
                  break;
              }
            },
            itemBuilder: (context) {
              final canExport = _mesh != null && !busy;
              return [
                PopupMenuItem(
                  value: 'open',
                  enabled: !busy,
                  child: const ListTile(leading: Icon(Icons.folder_open), title: Text('Open')),
                ),
                const PopupMenuDivider(),
                PopupMenuItem(
                  value: 'export-glb',
                  enabled: canExport,
                  height: 72,
                  child: const ListTile(
                    leading: SvgIcon('assets/icons/mesh/mesh_export.svg'),
                    title: Text('Export as GLB (reduced)'),
                    subtitle: Text('Keeps textures, downsampled to match'),
                  ),
                ),
                PopupMenuItem(
                  value: 'export-stl',
                  enabled: canExport,
                  height: 72,
                  child: const ListTile(
                    leading: SvgIcon('assets/icons/mesh/mesh_export.svg'),
                    title: Text('Export as STL (reduced)'),
                    subtitle: Text('Geometry only, no textures'),
                  ),
                ),
                const PopupMenuDivider(),
                const PopupMenuItem(
                  value: 'exit',
                  child: ListTile(leading: Icon(Icons.close), title: Text('Exit')),
                ),
              ];
            },
          ),
          // View > Scene, Facets, Mesh, Up axis - a full ExpansionTile-based
          // View menu (mirroring PartToolbar's) would be overkill for this
          // few entries.
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
                case 'up-axis-y':
                  _onUpAxisChanged(MeshUpAxis.y);
                  break;
                case 'up-axis-z':
                  _onUpAxisChanged(MeshUpAxis.z);
                  break;
                case 'mirror':
                  _onMirrorChanged(!_mirror);
                  break;
                case 'invert-visibility':
                  _invertBodyVisibility();
                  break;
                case 'reset-visibility':
                  _resetBodyVisibility();
                  break;
                case 'body-list':
                  _showBodyListSheet();
                  break;
              }
            },
            itemBuilder: (context) {
              final mesh = _mesh;
              final wireframeAvailable = mesh != null && mesh.triangleCount <= kMaxWireframeTriangles;
              final multiBodyMesh = _multiBodyMesh;
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
                const PopupMenuDivider(),
                // Some real-world files (a Blender export that skipped the
                // "+Y Up" axis conversion) aren't actually Y-up despite
                // claiming to be - see `mesh_data.dart`'s own doc comment on
                // `MeshUpAxis`/`applyUpAxis` for why this has to be a manual
                // choice rather than something auto-detected.
                CheckedPopupMenuItem(
                  value: 'up-axis-y',
                  checked: _upAxis == MeshUpAxis.y,
                  child: const Text('Up axis: Y (default)'),
                ),
                CheckedPopupMenuItem(
                  value: 'up-axis-z',
                  checked: _upAxis == MeshUpAxis.z,
                  child: const Text('Up axis: Z'),
                ),
                const PopupMenuDivider(),
                // Some real-world files (a Blender-exported drone
                // photogrammetry scan, confirmed by rendering both the
                // as-decoded and a left-right-flipped version for direct
                // comparison against the real property) genuinely have
                // mirrored vertex data - see `mesh_data.dart`'s own doc
                // comment on `applyMirror` for why this has to be a manual
                // choice too, same reasoning as "Up axis" above.
                CheckedPopupMenuItem(
                  value: 'mirror',
                  checked: _mirror,
                  child: const Text('Mirror'),
                ),
                // Multi-body STEP hide/show controls - only shown at all
                // once a STEP file with real bodies has loaded (a plain
                // STL/OBJ/glTF has no body concept to invert/reset/list).
                if (multiBodyMesh != null) ...[
                  const PopupMenuDivider(),
                  const PopupMenuItem(
                    value: 'invert-visibility',
                    child: ListTile(leading: Icon(Icons.flip_to_back), title: Text('Invert visibility')),
                  ),
                  const PopupMenuItem(
                    value: 'reset-visibility',
                    child: ListTile(leading: Icon(Icons.visibility), title: Text('Reset visibility')),
                  ),
                  const PopupMenuItem(
                    value: 'body-list',
                    child: ListTile(leading: Icon(Icons.list), title: Text('Body list…')),
                  ),
                ],
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
        return Center(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const CircularProgressIndicator(),
              const SizedBox(height: 16),
              Text(_stepBodiesTotal > 0
                  ? 'Loading body $_stepBodiesLoaded of $_stepBodiesTotal…'
                  : 'Decoding mesh…'),
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
        final materials = _materials!;
        return Stack(
          children: [
            Positioned.fill(
              child: _MeshViewerViewport(
                mesh: mesh,
                materials: materials,
                lightIntensity: _lightIntensity,
                showFacets: _showFacets,
                showWireframe: _showWireframe && mesh.triangleCount <= kMaxWireframeTriangles,
                bodies: _multiBodyMesh?.bodies,
                onBodyTap: _handleBodyTapped,
              ),
            ),
            if (_multiBodyMesh != null)
              Positioned(
                top: 8,
                right: 8,
                child: _InfoBanner(
                  text: '${_multiBodyMesh!.bodies.length} bodies '
                      '(${_multiBodyMesh!.bodies.where((b) => b.visible).length} visible)',
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

  /// One entry per [DecodedMesh.materialGroups] entry, or a single entry
  /// when [mesh] has none (STL/OBJ, or a single-primitive glTF) - see
  /// [buildMeshViewerMaterials]/[buildMeshViewerNodes].
  final List<PhysicallyBasedMaterial> materials;

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

  /// Non-null (and non-empty) only for a loaded multi-body STEP assembly -
  /// see `step_loader.dart`'s own `MeshBody`/`MultiBodyMesh` doc comments.
  /// `null`/empty for every other format, which keeps this widget's
  /// existing whole-mesh rendering path (plain [buildMeshViewerNodes],
  /// bulk [showFacets] toggling) completely unchanged - body-tagged
  /// rendering ([buildBodyTaggedMeshViewerNodes]/[addBodyNodes]/
  /// [removeBodyNodes]) only ever runs when this is populated.
  final List<MeshBody>? bodies;

  /// Tap-to-hide's own callback into the owning screen (which owns the
  /// actual [MeshBody.visible] mutation and its own `setState`) - see
  /// [_MeshViewerViewportState]'s own ray-hit-testing doc comment for why
  /// the hit test itself lives here (this widget owns the camera/gesture
  /// handling) while the visibility mutation lives one level up (the
  /// screen owns the [MultiBodyMesh] model, shared with the body-list
  /// sheet and the invert/reset buttons).
  final void Function(int bodyId)? onBodyTap;

  const _MeshViewerViewport({
    required this.mesh,
    required this.materials,
    required this.lightIntensity,
    required this.showFacets,
    required this.showWireframe,
    this.bodies,
    this.onBodyTap,
  });

  @override
  State<_MeshViewerViewport> createState() => _MeshViewerViewportState();
}

class _MeshViewerViewportState extends State<_MeshViewerViewport> {
  // Explicit `true`: this viewer has no perspective/orthographic control of
  // its own (unlike PartScreen/SketchScreen's View menu), so it keeps its
  // actual real-world behaviour (perspective, unaffected by
  // OrbitCamera.isPerspective's own default) rather than silently
  // inheriting the sketcher/Part-viewing default once that default started
  // actually taking effect (Phase 2 of the sketcher restructure).
  final OrbitCamera _camera = OrbitCamera()..isPerspective = true;
  Scene? _scene;
  String? _error;
  final Map<int, Offset> _activeTouches = {};

  List<Node> _faceNodes = const [];
  Node? _wireframeNode;
  bool _facesInScene = false;
  bool _wireframeInScene = false;

  /// Per-body Node groups, keyed by [MeshBody.id] - only populated when
  /// [widget.bodies] is non-null/non-empty (see [_buildFaceGeometry]).
  /// Empty (and unused) for every other mesh format.
  Map<int, List<Node>> _bodyNodesByBody = const {};

  /// Whether each body's own Nodes are *currently* present in [_scene] -
  /// the source of truth [_reconcileBodyNodes] diffs against, so toggling
  /// a body's [MeshBody.visible] (tap-to-hide, invert, reset, the body-list
  /// checkboxes - all mutate the same shared [MeshBody] instances the
  /// owning screen holds) only ever adds/removes exactly the Nodes whose
  /// desired membership actually changed, never a full rebuild.
  final Map<int, bool> _bodyNodesInScene = {};

  @override
  void initState() {
    super.initState();
    ensureSceneResourcesLoaded().then((_) {
      if (!mounted) return;
      setState(() {
        _scene = Scene();
        applySceneLighting(_scene!, widget.lightIntensity);
        _buildFaceGeometry();
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

  /// Builds [_faceNodes] (and, for a STEP file, [_bodyNodesByBody]) from
  /// [widget.mesh]/[widget.materials]/[widget.bodies] - shared by
  /// [initState] and [_rebuildGeometryForNewMesh] (a new [DecodedMesh]
  /// instance arrives either from the "Up axis"/"Mirror" toggles, or - for
  /// a streaming STEP load - every time another body's tessellation
  /// completes, see `step_loader.dart`'s `StepLoadAccumulator`).
  void _buildFaceGeometry() {
    final bodies = widget.bodies;
    if (bodies != null && bodies.isNotEmpty) {
      _bodyNodesByBody = buildBodyTaggedMeshViewerNodes(
        widget.mesh,
        widget.materials.first,
        [for (final b in bodies) (bodyId: b.id, startTriangle: b.startTriangle, triangleCount: b.triangleCount)],
      );
      _faceNodes = _bodyNodesByBody.values.expand((nodes) => nodes).toList();
      _bodyNodesInScene.clear();
    } else {
      _bodyNodesByBody = const {};
      _bodyNodesInScene.clear();
      _faceNodes = buildMeshViewerNodes(widget.mesh, widget.materials);
    }
  }

  /// Adds/removes [_faceNodes]/[_wireframeNode] to/from [_scene] to match
  /// [widget.showFacets]/[widget.showWireframe]. For a plain (non-STEP)
  /// mesh, only touches the [Scene] on an actual transition (tracked via
  /// [_facesInScene]/[_wireframeInScene]), never re-adding an
  /// already-present [Node]. For a STEP file with real [widget.bodies],
  /// delegates the "facets" half to [_reconcileBodyNodes] instead, so a
  /// body already hidden (tap-to-hide/checkbox) doesn't reappear the moment
  /// "Facets" is toggled back on. The wireframe [Node] itself is built
  /// lazily, once, the first time it's needed - a mesh the user never
  /// toggles wireframe on for never pays [buildMeshViewerWireframeNode]'s
  /// cost at all. (Scope cut: the wireframe overlay always covers the
  /// *whole* mesh regardless of per-body visibility - STEP assemblies
  /// large enough to need hide/show are already well above
  /// [kMaxWireframeTriangles] in practice, so this rarely matters; not
  /// attempted here.)
  void _syncFacetsAndWireframe() {
    final scene = _scene;
    if (scene == null) return;
    final bodies = widget.bodies;
    if (bodies != null && bodies.isNotEmpty) {
      _reconcileBodyNodes();
    } else if (widget.showFacets != _facesInScene) {
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

  /// The real per-body add/remove reconciliation for a STEP file -
  /// compares each [MeshBody]'s "should its own Nodes be in [_scene] right
  /// now" (facets shown overall AND that specific body currently visible)
  /// against [_bodyNodesInScene]'s last-known state, and only touches the
  /// ones that actually changed - O(bodies), never a geometry rebuild, no
  /// matter which single body's [MeshBody.visible] flag changed. This is
  /// what makes tap-to-hide/invert/reset/the body-list checkboxes all O(1)
  /// per body: none of them do anything more than mutate
  /// [MeshBody.visible] and call `setState` on the owning screen, which
  /// rebuilds this widget and lands back here via [didUpdateWidget].
  void _reconcileBodyNodes() {
    final scene = _scene;
    final bodies = widget.bodies;
    if (scene == null || bodies == null) return;
    for (final body in bodies) {
      final shouldBeInScene = widget.showFacets && body.visible;
      final isInScene = _bodyNodesInScene[body.id] ?? false;
      if (shouldBeInScene == isInScene) continue;
      if (shouldBeInScene) {
        addBodyNodes(scene, _bodyNodesByBody, body.id);
      } else {
        removeBodyNodes(scene, _bodyNodesByBody, body.id);
      }
      _bodyNodesInScene[body.id] = shouldBeInScene;
    }
    _facesInScene = widget.showFacets;
  }

  @override
  void didUpdateWidget(covariant _MeshViewerViewport oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.lightIntensity != oldWidget.lightIntensity) {
      final scene = _scene;
      if (scene != null) setState(() => applySceneLighting(scene, widget.lightIntensity));
    }
    // A different DecodedMesh instance - the View menu's "Up axis" toggle
    // re-derived a new one from the same raw decode (see
    // `mesh_viewer_screen.dart`'s own `_onUpAxisChanged`), or - for a
    // streaming STEP load - another body just finished tessellating (see
    // `step_loader.dart`'s `StepLoadAccumulator`, which produces a fresh
    // instance every time) - needs all-new geometry Nodes built from it;
    // [widget.materials] stays as-is (a texture doesn't depend on vertex
    // orientation), so this skips redoing that expensive step.
    if (_scene != null && !identical(widget.mesh, oldWidget.mesh)) {
      _rebuildGeometryForNewMesh();
    } else if (widget.showFacets != oldWidget.showFacets || widget.showWireframe != oldWidget.showWireframe) {
      setState(_syncFacetsAndWireframe);
    } else if (widget.bodies != null) {
      // Same mesh instance, same Facets/Wireframe toggles - but a body's
      // own [MeshBody.visible] may have changed (tap-to-hide, invert,
      // reset, or a body-list checkbox, all of which mutate the shared
      // [MeshBody] instances and `setState` on the owning screen, which
      // rebuilds this widget with the *same* `bodies` list reference).
      // Cheap - O(bodies) - to check unconditionally rather than trying to
      // detect "did anything actually change" up front.
      setState(_reconcileBodyNodes);
    }
  }

  void _rebuildGeometryForNewMesh() {
    final scene = _scene;
    if (scene == null) return;
    setState(() {
      if (_facesInScene) {
        for (final node in _faceNodes) {
          scene.remove(node);
        }
      }
      final wireframeNode = _wireframeNode;
      if (_wireframeInScene && wireframeNode != null) {
        scene.remove(wireframeNode);
      }
      _buildFaceGeometry();
      _wireframeNode = null;
      _facesInScene = false;
      _wireframeInScene = false;
      _syncFacetsAndWireframe();
      final bounds = _boundsOf(widget.mesh);
      _camera.setTarget(bounds.center);
      _camera.setZoomBoundsForRadius(bounds.radius);
    });
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

  /// Tap-to-hide's own "was this actually a tap, not a drag" tracking - the
  /// pointer id currently being watched as a tap candidate (`null` once
  /// disqualified: a second touch joined, or it moved further than
  /// [_kTapMovementThreshold] total), the position it went down at, and the
  /// summed distance it's moved since. A tap is only ever considered for a
  /// single active pointer (touch *or* mouse - unlike [_activeTouches],
  /// which only tracks touch for the existing orbit/pinch-pan gestures) -
  /// existing orbit/pan/zoom handling below is completely unaffected either
  /// way, since this is purely an observer over the same events, never
  /// consuming or gating them.
  int? _tapCandidatePointer;
  Offset? _tapDownPosition;
  double _tapMovement = 0;
  Size _viewportSize = Size.zero;

  static const double _kTapMovementThreshold = 8.0;

  void _handlePointerDown(PointerDownEvent event) {
    _tapCandidatePointer = event.pointer;
    _tapDownPosition = event.localPosition;
    _tapMovement = 0;
    if (event.kind == PointerDeviceKind.mouse) return;
    _activeTouches[event.pointer] = event.localPosition;
  }

  void _handlePointerMove(PointerMoveEvent event) {
    if (event.pointer == _tapCandidatePointer) {
      _tapMovement += event.delta.distance;
      // A mouse tap-to-hide only counts as a left-click drag, never a
      // right-button pan or a second touch joining (pinch/pan) - matches
      // the existing gesture split below (left button orbits, right pans).
      final disqualified = _tapMovement > _kTapMovementThreshold ||
          _activeTouches.length >= 2 ||
          (event.kind == PointerDeviceKind.mouse && event.buttons & kPrimaryMouseButton == 0);
      if (disqualified) _tapCandidatePointer = null;
    }
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
    if (event is PointerUpEvent &&
        event.pointer == _tapCandidatePointer &&
        _tapMovement <= _kTapMovementThreshold) {
      final downPosition = _tapDownPosition;
      if (downPosition != null) _handleTap(downPosition);
    }
    _tapCandidatePointer = null;
    _tapDownPosition = null;
  }

  /// Tap-to-hide: unprojects [screenPoint] into a world-space ray via the
  /// existing [OrbitCamera] (reusing [OrbitCamera.cameraFor]'s own
  /// [Camera.screenPointToRay] - the same ray-building call every other
  /// screen-space hit-test in this app already uses, e.g.
  /// `part_viewport.dart`'s section-drag hit-testing), then hands off to
  /// [_hitTestBody]. A no-op when [widget.bodies] is null/empty (every
  /// non-STEP format) or nothing was hit.
  void _handleTap(Offset screenPoint) {
    final bodies = widget.bodies;
    if (bodies == null || bodies.isEmpty || _viewportSize == Size.zero) return;
    final ray = _camera.cameraFor(_viewportSize).screenPointToRay(screenPoint, _viewportSize);
    final hitBodyId = _hitTestBody(ray, bodies, widget.mesh);
    if (hitBodyId != null) widget.onBodyTap?.call(hitBodyId);
  }

  /// Broad-phase (ray-vs-AABB against every visible body's own
  /// [MeshBody.bbox], sorted nearest-first) then narrow-phase (ray-vs-
  /// triangle against only the nearest candidate body's own triangle
  /// range, stopping at the first hit) - exactly the two-phase approach
  /// the plan calls for: cheap broad-phase over the (typically small)
  /// number of bodies, real per-triangle testing only against the single
  /// most-likely body. An already-hidden body is never a candidate at all
  /// (nothing to tap-to-hide further). Returns `null` on a total miss.
  int? _hitTestBody(vm.Ray ray, List<MeshBody> bodies, DecodedMesh mesh) {
    final candidates = <(double, MeshBody)>[];
    for (final body in bodies) {
      if (!body.visible) continue;
      final distance = _rayAabbEntryDistance(ray, body.bbox.min, body.bbox.max);
      if (distance != null) candidates.add((distance, body));
    }
    candidates.sort((a, b) => a.$1.compareTo(b.$1));

    final positions = mesh.positions;
    for (final (_, body) in candidates) {
      final end = body.startTriangle + body.triangleCount;
      for (var t = body.startTriangle; t < end; t++) {
        final base = t * 9;
        if (base + 8 >= positions.length) break;
        final a = vm.Vector3(positions[base], positions[base + 1], positions[base + 2]);
        final b = vm.Vector3(positions[base + 3], positions[base + 4], positions[base + 5]);
        final c = vm.Vector3(positions[base + 6], positions[base + 7], positions[base + 8]);
        if (_rayTriangleHits(ray.origin, ray.direction, a, b, c)) return body.id;
      }
    }
    return null;
  }

  /// Standard slab-method ray-vs-AABB test - returns the ray parameter `t`
  /// at which it enters the box (clamped to >= 0, i.e. "in front of the
  /// camera"), or `null` on a miss.
  double? _rayAabbEntryDistance(vm.Ray ray, vm.Vector3 min, vm.Vector3 max) {
    var tMin = double.negativeInfinity;
    var tMax = double.infinity;
    for (var axis = 0; axis < 3; axis++) {
      final origin = axis == 0 ? ray.origin.x : (axis == 1 ? ray.origin.y : ray.origin.z);
      final direction = axis == 0 ? ray.direction.x : (axis == 1 ? ray.direction.y : ray.direction.z);
      final lo = axis == 0 ? min.x : (axis == 1 ? min.y : min.z);
      final hi = axis == 0 ? max.x : (axis == 1 ? max.y : max.z);
      if (direction.abs() < 1e-12) {
        if (origin < lo || origin > hi) return null;
        continue;
      }
      var t1 = (lo - origin) / direction;
      var t2 = (hi - origin) / direction;
      if (t1 > t2) {
        final tmp = t1;
        t1 = t2;
        t2 = tmp;
      }
      if (t1 > tMin) tMin = t1;
      if (t2 < tMax) tMax = t2;
      if (tMin > tMax) return null;
    }
    if (tMax < 0) return null;
    return tMin < 0 ? 0 : tMin;
  }

  /// Möller-Trumbore ray-triangle intersection - `true` iff [ray origin,
  /// direction] hits triangle (a, b, c) at a positive parameter.
  bool _rayTriangleHits(vm.Vector3 origin, vm.Vector3 direction, vm.Vector3 a, vm.Vector3 b, vm.Vector3 c) {
    final edge1 = b - a;
    final edge2 = c - a;
    final h = direction.cross(edge2);
    final det = edge1.dot(h);
    if (det.abs() < 1e-12) return false;
    final invDet = 1 / det;
    final s = origin - a;
    final u = s.dot(h) * invDet;
    if (u < 0 || u > 1) return false;
    final q = s.cross(edge1);
    final v = direction.dot(q) * invDet;
    if (v < 0 || u + v > 1) return false;
    final t = edge2.dot(q) * invDet;
    return t > 1e-9;
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
                painter: _ViewerScenePainter(scene: scene, camera: _camera, size: size),
              ),
            ),
            if (MeshViewerPreferences.debugShowCameraOrientation)
              DebugCameraOrientationOverlay(camera: _camera.cameraFor(size)),
          ],
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
