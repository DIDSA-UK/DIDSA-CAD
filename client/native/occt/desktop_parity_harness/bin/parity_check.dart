// Minimal smoke-test harness for didsa_occt_ffi - loads the host-built
// shared library and a STEP file path, both given on the command line, and
// prints each free-shape body's name/bbox/triangle count. Not a
// cross-check against the backend's own pythonocc-core output (unlike
// slvs's own parity_check.dart, which has real captured ground truth to
// compare against) - this is a smaller smoke test confirming the shim loads
// and the whole load -> enumerate -> tessellate pipeline runs end to end
// without crashing, matching the plan's own "validation and testing" scope
// for this harness (manual/CI-optional, like slvs's own).
//
// Run with: dart run bin/parity_check.dart <path-to-didsa_occt_ffi shared library> <path-to.step>
import 'dart:ffi' as ffi;
import 'dart:io';

import 'package:ffi/ffi.dart' as pkg_ffi;

typedef _LoadStepNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);
typedef _LoadStepDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<pkg_ffi.Utf8>);

typedef _DestroyDocNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyDocDart = void Function(ffi.Pointer<ffi.Void>);

typedef _LastErrorNative = ffi.Pointer<pkg_ffi.Utf8> Function();
typedef _LastErrorDart = ffi.Pointer<pkg_ffi.Utf8> Function();

typedef _BodyCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _BodyCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _BodyNameNative = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef _BodyNameDart = ffi.Pointer<pkg_ffi.Utf8> Function(ffi.Pointer<ffi.Void>, int);

typedef _BodyBboxNative = ffi.Int32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);
typedef _BodyBboxDart = int Function(ffi.Pointer<ffi.Void>, int, ffi.Pointer<ffi.Double>, ffi.Pointer<ffi.Double>);

typedef _TessellateNative = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Double, ffi.Double);
typedef _TessellateDart = ffi.Pointer<ffi.Void> Function(ffi.Pointer<ffi.Void>, int, double, double);

typedef _TriangleCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef _TriangleCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef _DestroyTessNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef _DestroyTessDart = void Function(ffi.Pointer<ffi.Void>);

void main(List<String> args) {
  if (args.length < 2) {
    stderr.writeln('usage: dart run bin/parity_check.dart <path-to-didsa_occt_ffi shared library> <path-to.step>');
    exit(2);
  }
  final lib = ffi.DynamicLibrary.open(args[0]);
  final stepPath = args[1];

  final loadStep = lib.lookupFunction<_LoadStepNative, _LoadStepDart>('occt_document_load_step');
  final destroyDoc = lib.lookupFunction<_DestroyDocNative, _DestroyDocDart>('occt_document_destroy');
  final lastError = lib.lookupFunction<_LastErrorNative, _LastErrorDart>('occt_last_error');
  final bodyCount = lib.lookupFunction<_BodyCountNative, _BodyCountDart>('occt_document_body_count');
  final bodyName = lib.lookupFunction<_BodyNameNative, _BodyNameDart>('occt_document_body_name');
  final bodyBbox = lib.lookupFunction<_BodyBboxNative, _BodyBboxDart>('occt_document_body_bbox');
  final tessellate = lib.lookupFunction<_TessellateNative, _TessellateDart>('occt_tessellate_body');
  final triangleCount =
      lib.lookupFunction<_TriangleCountNative, _TriangleCountDart>('occt_tessellation_triangle_count');
  final destroyTess = lib.lookupFunction<_DestroyTessNative, _DestroyTessDart>('occt_tessellation_destroy');

  final pathPtr = stepPath.toNativeUtf8();
  final doc = loadStep(pathPtr);
  pkg_ffi.malloc.free(pathPtr);
  if (doc == ffi.nullptr) {
    stderr.writeln('Failed to load STEP file: ${lastError().toDartString()}');
    exit(1);
  }

  try {
    final count = bodyCount(doc);
    stdout.writeln('bodies: $count');
    final minPtr = pkg_ffi.malloc<ffi.Double>(3);
    final maxPtr = pkg_ffi.malloc<ffi.Double>(3);
    try {
      for (var i = 0; i < count; i++) {
        final name = bodyName(doc, i).toDartString();
        final bboxOk = bodyBbox(doc, i, minPtr, maxPtr) == 0;
        final bboxStr = bboxOk
            ? '[(${minPtr[0]}, ${minPtr[1]}, ${minPtr[2]}) -> (${maxPtr[0]}, ${maxPtr[1]}, ${maxPtr[2]})]'
            : '(no bbox: ${lastError().toDartString()})';
        stdout.write('  body $i: name="$name" bbox=$bboxStr');

        final tess = tessellate(doc, i, 0.5, 0.5);
        if (tess == ffi.nullptr) {
          stdout.writeln(' tessellation FAILED: ${lastError().toDartString()}');
          continue;
        }
        try {
          stdout.writeln(' triangles=${triangleCount(tess)}');
        } finally {
          destroyTess(tess);
        }
      }
    } finally {
      pkg_ffi.malloc.free(minPtr);
      pkg_ffi.malloc.free(maxPtr);
    }
  } finally {
    destroyDoc(doc);
  }
}
