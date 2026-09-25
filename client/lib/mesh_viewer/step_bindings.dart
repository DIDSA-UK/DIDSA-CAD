// Low-level dart:ffi bindings for the didsa_occt_ffi shared library built
// from client/native/occt/ (see that directory's CMakeLists.txt for the
// build recipe, and occt_ffi_shim.h for the exact C API this mirrors) -
// same hand-written (no ffigen) style as client/lib/sketch/local_solver/
// slvs_bindings.dart. This file only translates native calls into Dart
// function pointers - no STEP/mesh domain knowledge; see step_loader.dart
// for the isolate-based streaming loader built on top of it.
import 'dart:ffi' as ffi;

import 'package:ffi/ffi.dart' as pkg_ffi;

typedef LoadStepNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef LoadStepDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);

typedef DestroyDocNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef DestroyDocDart = void Function(ffi.Pointer<ffi.Void>);

typedef LastErrorNative = ffi.Pointer<pkg_ffi.Utf8> Function();
typedef LastErrorDart = ffi.Pointer<pkg_ffi.Utf8> Function();

typedef BodyCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef BodyCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef BodyNameNative = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef BodyNameDart = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void>, int);

typedef BodyBboxNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef BodyBboxDart = int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

typedef TessellateNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double, ffi.Double);
typedef TessellateDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, double, double);

typedef TriangleCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef TriangleCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef CopyDoublesNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Double>);
typedef CopyDoublesDart = int Function(ffi.Pointer<ffi.Void>, ffi.Pointer<ffi.Double>);

typedef DestroyTessNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef DestroyTessDart = void Function(ffi.Pointer<ffi.Void>);

/// One Dart function pointer per `occt_ffi_shim.h` export - see that header
/// for the exact C signatures and the exception/sentinel-value contract at
/// the FFI boundary (nullptr/-1 on failure, [lastError] for a human-readable
/// message).
class StepOcctBindings {
  final LoadStepDart _loadStep;
  final DestroyDocDart destroyDocument;
  final LastErrorDart _lastError;
  final BodyCountDart bodyCount;
  final BodyNameDart _bodyName;
  final BodyBboxDart bodyBbox;
  final TessellateDart tessellateBody;
  final TriangleCountDart triangleCount;
  final CopyDoublesDart copyPositions;
  final CopyDoublesDart copyNormals;
  final DestroyTessDart destroyTessellation;

  StepOcctBindings(ffi.DynamicLibrary lib)
      : _loadStep = lib.lookupFunction<LoadStepNative, LoadStepDart>('occt_document_load_step'),
        destroyDocument = lib.lookupFunction<DestroyDocNative, DestroyDocDart>('occt_document_destroy'),
        _lastError = lib.lookupFunction<LastErrorNative, LastErrorDart>('occt_last_error'),
        bodyCount = lib.lookupFunction<BodyCountNative, BodyCountDart>('occt_document_body_count'),
        _bodyName = lib.lookupFunction<BodyNameNative, BodyNameDart>('occt_document_body_name'),
        bodyBbox = lib.lookupFunction<BodyBboxNative, BodyBboxDart>('occt_document_body_bbox'),
        tessellateBody = lib.lookupFunction<TessellateNative, TessellateDart>('occt_tessellate_body'),
        triangleCount =
            lib.lookupFunction<TriangleCountNative, TriangleCountDart>('occt_tessellation_triangle_count'),
        copyPositions =
            lib.lookupFunction<CopyDoublesNative, CopyDoublesDart>('occt_tessellation_copy_positions'),
        copyNormals = lib.lookupFunction<CopyDoublesNative, CopyDoublesDart>('occt_tessellation_copy_normals'),
        destroyTessellation =
            lib.lookupFunction<DestroyTessNative, DestroyTessDart>('occt_tessellation_destroy');

  /// Wraps `occt_document_load_step`'s own `const char*` path argument -
  /// allocates/frees the native UTF-8 copy of [path] itself, so no caller
  /// has to touch `package:ffi`'s `toNativeUtf8`/`malloc.free` directly for
  /// this one call.
  ffi.Pointer<ffi.Void> loadStep(String path) {
    final pathPtr = path.toNativeUtf8();
    try {
      return _loadStep(pathPtr);
    } finally {
      pkg_ffi.malloc.free(pathPtr);
    }
  }

  /// `occt_last_error()`'s current message - never null (an empty string
  /// when nothing has failed yet on this thread, per that function's own
  /// doc comment).
  String lastError() => _lastError().toDartString();

  /// `occt_document_body_name(doc, index)`'s current name - empty string
  /// for an unnamed body or an out-of-range index (caller synthesizes
  /// "Body N" in that case - see step_loader.dart's `MeshBody`).
  String bodyName(ffi.Pointer<ffi.Void> doc, int index) => _bodyName(doc, index).toDartString();
}
