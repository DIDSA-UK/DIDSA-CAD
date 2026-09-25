/// STEP (multi-body, B-rep) import for the Mesh Viewer, via the trimmed
/// OCCT wrapper vendored at `client/native/occt/` (occt_ffi_shim.h/.cpp) -
/// called through `dart:ffi` (`step_bindings.dart`). Kept as its own file,
/// separate from `mesh_data.dart`'s pure STL/OBJ/glTF decoders, since this
/// one genuinely needs `dart:ffi` and platform-specific native library
/// loading - `mesh_data.dart`'s own top-of-file doc comment is explicit that
/// its whole point is staying GPU/native-independent so it's unit-testable
/// with plain `flutter test`; this file cannot make that same claim for its
/// FFI-touching half (see `computeBodyDecimationStrides`/`MeshBody`/
/// `MultiBodyMesh` below for the parts of *this* file that still are pure
/// and are exercised directly by `test/mesh_viewer/step_body_visibility_test.dart`).
///
/// Fully offline: no server round-trip at all, same "the whole point" as
/// every other format this viewer already reads - see `mesh_data.dart`'s own
/// header doc comment.
library;

import 'dart:async';
import 'dart:ffi' as ffi;
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:ffi/ffi.dart' as pkg_ffi;
import 'package:vector_math/vector_math.dart' as vm;

import 'mesh_data.dart';
import 'mesh_viewer_preferences.dart';
import 'step_bindings.dart';

/// One body inside a multi-body STEP assembly - a contiguous triangle range
/// within [MultiBodyMesh.mesh]'s own flat triangle soup (never interleaved
/// with another body's triangles, same "contiguous range" convention
/// `MeshMaterialGroup` already uses in `mesh_data.dart`), plus the
/// hide/show state the Mesh Viewer's tap-to-hide/invert/reset feature reads
/// and writes directly.
class MeshBody {
  final int id;

  /// The body's own XCAF label name, or a synthesized "Body N" (1-based,
  /// matching how bodies are listed to a person, not [id]'s own 0-based
  /// index) when the STEP file's label carries no name at all - see
  /// `occt_ffi_shim.h`'s own doc comment on `occt_document_body_name` for
  /// why that synthesis happens here, not in the native shim.
  final String name;

  int startTriangle;
  int triangleCount;

  /// Axis-aligned bounding box in the same coordinate space as
  /// [MultiBodyMesh.mesh]'s own vertex positions - computed natively via
  /// `BRepBndLib::Add`/`Bnd_Box` (see `occt_document_body_bbox`), used both
  /// for the assembly-wide bbox-diagonal deflection calculation (see
  /// [StepTessellationQuality]) and for tap-to-hide's ray-vs-AABB
  /// broad-phase (`mesh_viewer_screen.dart`).
  final ({vm.Vector3 min, vm.Vector3 max}) bbox;

  bool visible;

  MeshBody({
    required this.id,
    required this.name,
    required this.startTriangle,
    required this.triangleCount,
    required this.bbox,
    this.visible = true,
  });
}

/// A decoded multi-body STEP assembly - [mesh] is the same flat triangle
/// soup every other format in this viewer already renders
/// (`mesh_viewer_render.dart`'s `buildMeshViewerNodes` doesn't need to know
/// or care that its ranges came from STEP bodies rather than glTF
/// `materialGroups`); [bodies] partitions it into per-body ranges,
/// orthogonal to (and, for STEP, exclusive of - STEP has no glTF-style
/// per-primitive material/texture concept) [DecodedMesh.materialGroups].
class MultiBodyMesh {
  DecodedMesh mesh;
  final List<MeshBody> bodies;

  MultiBodyMesh({required this.mesh, required this.bodies});

  /// Flips every body's [MeshBody.visible] flag - the Mesh Viewer's
  /// "Invert visibility" button. Pure model mutation; the caller
  /// (`mesh_viewer_screen.dart`) is responsible for then reconciling the
  /// `flutter_scene` `Scene`'s own Nodes against the new flags (see
  /// `mesh_viewer_render.dart`'s `addBodyNodes`/`removeBodyNodes`).
  void invertVisibility() {
    for (final body in bodies) {
      body.visible = !body.visible;
    }
  }

  /// Sets every body back to visible - the Mesh Viewer's "Reset visibility"
  /// button.
  void resetVisibility() {
    for (final body in bodies) {
      body.visible = true;
    }
  }
}

/// Computes a per-body decimation stride (1 = keep every triangle) given
/// each body's own already-tessellated triangle count and an optional
/// overall [maxTriangles] budget - a pure, FFI-free function (unlike the
/// rest of this file) so it's directly unit-testable (see
/// `test/mesh_viewer/step_body_visibility_test.dart`).
///
/// Mirrors `mesh_data.dart`'s `_decimationStride` in spirit (stride-skip,
/// not vertex clustering - see that function's own doc comment for why),
/// but never merges two bodies' ranges the way a single whole-mesh stride
/// would: each body is decimated *independently*, using its own share of
/// [maxTriangles] proportional to its own share of the assembly's total
/// triangle count - a body with 90% of the assembly's triangles gets 90% of
/// the budget, not an equal 1/bodyCount split that would over-decimate a
/// large body and waste budget on tiny ones.
///
/// Returns an all-1s list unchanged (no decimation) when [maxTriangles] is
/// null, the assembly is already within budget, or [triangleCounts] is
/// empty/all-zero.
List<int> computeBodyDecimationStrides(List<int> triangleCounts, int? maxTriangles) {
  final total = triangleCounts.fold<int>(0, (a, b) => a + b);
  if (maxTriangles == null || total <= maxTriangles || total <= 0) {
    return List.filled(triangleCounts.length, 1);
  }
  return [
    for (final count in triangleCounts)
      count <= 0 ? 1 : _strideForProportionalShare(count, total, maxTriangles),
  ];
}

int _strideForProportionalShare(int count, int total, int maxTriangles) {
  final share = (count / total * maxTriangles).ceil();
  final budget = share < 1 ? 1 : (share > count ? count : share);
  return (count / budget).ceil();
}

/// Opens the platform-appropriate build of `didsa_occt_ffi` (see
/// `client/native/occt/CMakeLists.txt` for how it's built) - returns `null`
/// on *any* failure (missing library, wrong architecture, unsupported
/// platform) rather than throwing, since there is no fallback for STEP
/// import to degrade to except disabling it entirely (see this function's
/// own call sites: `mesh_viewer_screen.dart` only lists `.step`/`.stp` as
/// pickable extensions when this returns non-null, checked once at screen
/// init and cached - see that file's own doc comment).
///
/// Per-platform load convention mirrors `local_sketch_solver.dart`'s
/// `loadSlvsBindings`, extended to cover every real platform this app
/// ships to (there is no macOS or web target - see
/// `mesh_viewer_screen.dart`'s own top-of-file doc comment):
///   - Android/Linux: `libdidsa_occt_ffi.so`, loaded by name (a normal
///     bundled/co-located native library).
///   - Windows: `didsa_occt_ffi.dll`.
///   - iOS: `DynamicLibrary.process()` - the library is statically linked
///     into the app binary itself there (see `client/native/occt/
///     README_ios.md`'s own packaging notes), so every exported `occt_*`
///     symbol is already resolvable process-wide with no `.open(...)` path
///     needed at all.
StepOcctBindings? loadOcctBindingsOrNull() {
  try {
    final ffi.DynamicLibrary lib;
    if (Platform.isAndroid || Platform.isLinux) {
      lib = ffi.DynamicLibrary.open('libdidsa_occt_ffi.so');
    } else if (Platform.isWindows) {
      lib = ffi.DynamicLibrary.open('didsa_occt_ffi.dll');
    } else if (Platform.isIOS) {
      lib = ffi.DynamicLibrary.process();
    } else {
      throw UnsupportedError(
        'STEP import via didsa_occt_ffi has no build for this platform (only '
        'Android, Windows, Linux, and iOS are supported).',
      );
    }
    return StepOcctBindings(lib);
  } catch (_) {
    return null;
  }
}

/// One update from [loadStepFile]'s streamed load - a closed hierarchy so
/// `switch` on it is exhaustive at the call site.
sealed class StepLoadEvent {}

/// Sent once, immediately after every body's cheap metadata (name/bbox) has
/// been enumerated - lets the UI show a body list/progress ("Loading body 1
/// of 12") long before any tessellation has happened at all. Every
/// [bodies] entry has `triangleCount == 0`/`startTriangle == 0` at this
/// point; [StepLoadBodyMeshEvent]s (below) fill each one in as they
/// complete, in order.
class StepLoadBodiesEvent extends StepLoadEvent {
  final List<MeshBody> bodies;
  StepLoadBodiesEvent(this.bodies);
}

/// Sent once per body, in document order, as its tessellation completes -
/// [positions]/[normals] are that body's own flat triangle soup (already
/// decimated per [computeBodyDecimationStrides] if the assembly exceeded
/// budget), ready to be appended to the growing [MultiBodyMesh.mesh].
class StepLoadBodyMeshEvent extends StepLoadEvent {
  final int bodyIndex;
  final Float32List positions;
  final Float32List normals;
  StepLoadBodyMeshEvent(this.bodyIndex, this.positions, this.normals);
}

class StepLoadErrorEvent extends StepLoadEvent {
  final String message;
  StepLoadErrorEvent(this.message);
}

/// Sent once, after every body has produced its [StepLoadBodyMeshEvent] (or
/// been skipped on its own per-body failure - a single bad body doesn't
/// abort the whole assembly's load).
class StepLoadDoneEvent extends StepLoadEvent {}

/// Loads [path] (a real filesystem path) as a multi-body STEP assembly,
/// streaming progress back as a [Stream] rather than a single
/// request/response `compute()` call - `compute()` can't stream multiple
/// messages back (see this file's own header comment on why a long-lived
/// worker [Isolate] is used instead), which matters here because a large
/// assembly's later bodies can take much longer to tessellate than its
/// earlier ones, and the viewport should show each finished body as soon as
/// it's ready rather than waiting for all of them.
///
/// [maxTriangles]/[quality] drive [computeBodyDecimationStrides] and the
/// assembly-bbox-diagonal-based linear deflection respectively - see
/// [StepTessellationQuality]'s own doc comment.
///
/// KNOWN GAP: does not yet support deprioritizing/skipping a body's
/// tessellation if the caller hides it mid-load (the plan's own "if the
/// user hides a body while it's still queued for tessellation" mechanism) -
/// every body is always fully tessellated once loading starts. Flagged
/// here rather than silently omitted; would need a second SendPort
/// (worker -> caller is already covered by [receivePort] below, but
/// caller -> worker has no channel yet) carrying live visibility updates
/// into the isolate.
Stream<StepLoadEvent> loadStepFile(
  String path, {
  required int? maxTriangles,
  required StepTessellationQuality quality,
}) {
  final controller = StreamController<StepLoadEvent>();
  final receivePort = ReceivePort();
  Isolate? spawnedIsolate;

  receivePort.listen((dynamic message) {
    final map = message as Map<Object?, Object?>;
    switch (map['type']) {
      case 'bodies':
        final names = (map['names'] as List).cast<String>();
        final mins = (map['mins'] as List).cast<List>();
        final maxs = (map['maxs'] as List).cast<List>();
        final bodies = <MeshBody>[
          for (var i = 0; i < names.length; i++)
            MeshBody(
              id: i,
              name: names[i].isEmpty ? 'Body ${i + 1}' : names[i],
              startTriangle: 0,
              triangleCount: 0,
              bbox: (
                min: vm.Vector3((mins[i][0] as num).toDouble(), (mins[i][1] as num).toDouble(),
                    (mins[i][2] as num).toDouble()),
                max: vm.Vector3((maxs[i][0] as num).toDouble(), (maxs[i][1] as num).toDouble(),
                    (maxs[i][2] as num).toDouble()),
              ),
            ),
        ];
        controller.add(StepLoadBodiesEvent(bodies));
      case 'body_mesh':
        controller.add(StepLoadBodyMeshEvent(
          map['index']! as int,
          map['positions']! as Float32List,
          map['normals']! as Float32List,
        ));
      case 'error':
        controller.add(StepLoadErrorEvent(map['message']! as String));
      case 'done':
        controller.add(StepLoadDoneEvent());
        controller.close();
        receivePort.close();
        spawnedIsolate?.kill();
    }
  });

  Isolate.spawn(
    _stepLoaderIsolateEntry,
    (
      receivePort.sendPort,
      path,
      maxTriangles,
      quality.diagonalFraction,
      StepTessellationQuality.angularDeflectionRadians,
    ),
  ).then((isolate) {
    spawnedIsolate = isolate;
  }, onError: (Object error) {
    controller.add(StepLoadErrorEvent('Could not start the STEP loader isolate: $error'));
    controller.add(StepLoadDoneEvent());
    controller.close();
    receivePort.close();
  });

  controller.onCancel = () {
    spawnedIsolate?.kill();
    receivePort.close();
  };

  return controller.stream;
}

/// The worker isolate's own entry point - opens its own [StepOcctBindings]
/// (isolates don't share memory, so every FFI handle this touches is
/// created and destroyed entirely within this isolate; only primitive
/// triangle/name/bbox data ever crosses [sendPort] - see this file's own
/// header comment). Runs entirely off the main isolate: both the STEP
/// parse and every body's tessellation can be multi-second, CPU-bound
/// native calls for a large assembly.
void _stepLoaderIsolateEntry((SendPort, String, int?, double, double) args) {
  final (sendPort, path, maxTriangles, diagonalFraction, angularDeflection) = args;

  final bindings = loadOcctBindingsOrNull();
  if (bindings == null) {
    sendPort.send({'type': 'error', 'message': 'STEP support is not available on this build/device.'});
    sendPort.send({'type': 'done'});
    return;
  }

  final doc = bindings.loadStep(path);
  if (doc == ffi.nullptr) {
    sendPort.send({'type': 'error', 'message': bindings.lastError()});
    sendPort.send({'type': 'done'});
    return;
  }

  try {
    final count = bindings.bodyCount(doc);
    if (count < 0) {
      sendPort.send({'type': 'error', 'message': bindings.lastError()});
      return;
    }

    final names = <String>[];
    final mins = <List<double>>[];
    final maxs = <List<double>>[];
    var assemblyMin = vm.Vector3.zero();
    var assemblyMax = vm.Vector3.zero();
    var haveBounds = false;

    final minPtr = pkg_ffi.malloc<ffi.Double>(3);
    final maxPtr = pkg_ffi.malloc<ffi.Double>(3);
    try {
      for (var i = 0; i < count; i++) {
        names.add(bindings.bodyName(doc, i));
        final ok = bindings.bodyBbox(doc, i, minPtr, maxPtr) == 0;
        final bodyMin = ok ? [minPtr[0], minPtr[1], minPtr[2]] : [0.0, 0.0, 0.0];
        final bodyMax = ok ? [maxPtr[0], maxPtr[1], maxPtr[2]] : [0.0, 0.0, 0.0];
        mins.add(bodyMin);
        maxs.add(bodyMax);
        if (ok) {
          final bMin = vm.Vector3(bodyMin[0], bodyMin[1], bodyMin[2]);
          final bMax = vm.Vector3(bodyMax[0], bodyMax[1], bodyMax[2]);
          if (!haveBounds) {
            assemblyMin = bMin;
            assemblyMax = bMax;
            haveBounds = true;
          } else {
            assemblyMin = vm.Vector3(math.min(assemblyMin.x, bMin.x), math.min(assemblyMin.y, bMin.y),
                math.min(assemblyMin.z, bMin.z));
            assemblyMax = vm.Vector3(math.max(assemblyMax.x, bMax.x), math.max(assemblyMax.y, bMax.y),
                math.max(assemblyMax.z, bMax.z));
          }
        }
      }
    } finally {
      pkg_ffi.malloc.free(minPtr);
      pkg_ffi.malloc.free(maxPtr);
    }

    sendPort.send({'type': 'bodies', 'names': names, 'mins': mins, 'maxs': maxs});

    final diagonal = haveBounds ? (assemblyMax - assemblyMin).length : 0.0;
    // A degenerate/zero-size assembly (or a single-point body) has no
    // meaningful diagonal to derive a fraction from - falls back to a small
    // fixed absolute deflection rather than dividing into a zero/NaN
    // linear_deflection, which BRepMesh_IncrementalMesh would reject.
    final linearDeflection = diagonal > 1e-9 ? diagonal * diagonalFraction : 0.01;

    // Tessellate every body first (holding native tessellation handles, not
    // yet copying any triangle data into Dart) so each body's own *exact*
    // triangle count is known before computeBodyDecimationStrides ever
    // runs - see that function's own doc comment for why this needs real
    // counts, not a bbox-based estimate, to honor "proportional to its own
    // triangle count" exactly.
    final tessHandles = <ffi.Pointer<ffi.Void>>[];
    final counts = <int>[];
    for (var i = 0; i < count; i++) {
      final tess = bindings.tessellateBody(doc, i, linearDeflection, angularDeflection);
      tessHandles.add(tess);
      counts.add(tess == ffi.nullptr ? 0 : bindings.triangleCount(tess));
    }

    final strides = computeBodyDecimationStrides(counts, maxTriangles);

    for (var i = 0; i < count; i++) {
      final tess = tessHandles[i];
      final triangleCount = counts[i];
      if (tess == ffi.nullptr || triangleCount <= 0) {
        sendPort.send({'type': 'body_mesh', 'index': i, 'positions': Float32List(0), 'normals': Float32List(0)});
        continue;
      }
      final stride = strides[i];
      final keptCount = (triangleCount / stride).ceil();
      final rawPositions = pkg_ffi.malloc<ffi.Double>(triangleCount * 9);
      final rawNormals = pkg_ffi.malloc<ffi.Double>(triangleCount * 9);
      try {
        bindings.copyPositions(tess, rawPositions);
        bindings.copyNormals(tess, rawNormals);
        final positions = Float32List(keptCount * 9);
        final normals = Float32List(keptCount * 9);
        var outTriangle = 0;
        for (var t = 0; t < triangleCount; t += stride) {
          final srcBase = t * 9;
          final dstBase = outTriangle * 9;
          for (var k = 0; k < 9; k++) {
            positions[dstBase + k] = rawPositions[srcBase + k];
            normals[dstBase + k] = rawNormals[srcBase + k];
          }
          outTriangle++;
        }
        sendPort.send({'type': 'body_mesh', 'index': i, 'positions': positions, 'normals': normals});
      } finally {
        pkg_ffi.malloc.free(rawPositions);
        pkg_ffi.malloc.free(rawNormals);
        bindings.destroyTessellation(tess);
      }
    }

    sendPort.send({'type': 'done'});
  } catch (error) {
    sendPort.send({'type': 'error', 'message': 'Unexpected error loading STEP file: $error'});
    sendPort.send({'type': 'done'});
  } finally {
    bindings.destroyDocument(doc);
  }
}

/// Assembles a growing [MultiBodyMesh] from [loadStepFile]'s own streamed
/// events - owns the running concatenation of every arrived body's
/// positions/normals into one flat, growing [DecodedMesh], and fills in
/// each [MeshBody]'s [MeshBody.startTriangle]/[MeshBody.triangleCount] as
/// its mesh event arrives. UVs are always all-zero (STEP/B-rep has no
/// texture-coordinate concept - same convention `DecodedMesh.uvs` already
/// uses for a texture-less STL/OBJ source, see `mesh_data.dart`'s own doc
/// comment).
class StepLoadAccumulator {
  final List<MeshBody> _bodies = [];
  final List<double> _positions = [];
  final List<double> _normals = [];

  List<MeshBody> get bodies => List.unmodifiable(_bodies);

  void addBodies(List<MeshBody> bodies) {
    _bodies
      ..clear()
      ..addAll(bodies);
  }

  void addBodyMesh(int bodyIndex, Float32List positions, Float32List normals) {
    final body = _bodies[bodyIndex];
    body.startTriangle = _positions.length ~/ 9;
    body.triangleCount = positions.length ~/ 9;
    _positions.addAll(positions);
    _normals.addAll(normals);
  }

  MultiBodyMesh toMultiBodyMesh() {
    final positions = Float32List.fromList(_positions);
    final normals = Float32List.fromList(_normals);
    final triangleCount = positions.length ~/ 3;
    return MultiBodyMesh(
      mesh: DecodedMesh(
        positions: positions,
        normals: normals,
        uvs: Float32List(triangleCount * 2),
      ),
      bodies: _bodies,
    );
  }
}
