// Production dart:ffi shim over a trimmed OCCT (OpenCascade) build - reads a
// STEP file (possibly multi-body) and tessellates each body into a flat
// triangle soup, so the Mesh Viewer (client/lib/mesh_viewer/) can render it
// entirely offline, with no backend involved at all. Mirrors
// client/native/slvs/slvs_ffi_shim.h's own conventions exactly: opaque
// handles, a thread-local last-error string, every exported function catches
// C++ exceptions at the boundary (a C++ exception must never unwind across
// dart:ffi), and caller-owned output buffers.
//
// Enumeration (occt_document_body_count/_body_name/_body_bbox) is
// deliberately a separate, fast step from tessellation
// (occt_tessellate_body) - see step_loader.dart's own doc comment for why:
// the Dart-side loader streams body metadata back to the UI immediately,
// then tessellates bodies one at a time, so a large assembly shows *something*
// long before every body has been meshed, and a body the user hides before
// its tessellation starts can be skipped entirely.
#ifndef DIDSA_OCCT_FFI_SHIM_H
#define DIDSA_OCCT_FFI_SHIM_H

#include <stdint.h>

// Same reasoning as slvs_ffi_shim.h's own DIDSA_SLVS_API macro: a Windows
// DLL doesn't export non-static symbols by default, unlike an ELF .so
// (Android/Linux's actual target) - dart:ffi's DynamicLibrary.lookup would
// fail to find any of these without this.
#if defined(_WIN32)
#define DIDSA_OCCT_API __declspec(dllexport)
#else
#define DIDSA_OCCT_API __attribute__((visibility("default")))
#endif

extern "C" {

// Opaque handle to one loaded STEP document (an XCAF TDocStd_Document plus
// its enumerated free-shape bodies) - owns every TopoDS_Shape reachable from
// it until occt_document_destroy runs. Never shared across isolates (Dart
// isolates don't share memory - only primitive triangle/name/bbox data
// crosses a SendPort, never this pointer itself - see step_loader.dart).
typedef void* OcctDocumentHandle;

// Opaque handle to one body's own tessellation result (a flat, de-indexed
// triangle soup - no shared-vertex indexing crosses the FFI boundary, same
// convention DecodedMesh already uses - see mesh_data.dart). Destroyed
// separately from the OcctDocumentHandle it came from, once its
// positions/normals have been copied out via occt_tessellation_copy_*.
typedef void* OcctTessellationHandle;

// Reads and parses [path] (a real filesystem path - never a content-provider
// URI; the Dart side already resolves that the same way file_picker's own
// `.path` does elsewhere in this app) via STEPCAFControl_Reader
// (SetNameMode(true)), then walks XCAFDoc_DocumentTool::ShapeTool's
// GetFreeShapes to enumerate every top-level body - unlike the backend's own
// extract_step_metadata (backend/app/document/import_geometry.py), which
// only reads Value(1) (the first free shape) for its Part-Properties-only
// use case, this walks *all* of them, since a real multi-body STEP assembly
// is exactly what this viewer's tap-to-hide/invert/reset feature is for.
// Returns nullptr (and sets the last-error string - see occt_last_error) on
// any failure: file not found, not a STEP file, malformed STEP, or an
// unhandled OCCT exception.
DIDSA_OCCT_API OcctDocumentHandle occt_document_load_step(const char* path);

DIDSA_OCCT_API void occt_document_destroy(OcctDocumentHandle doc);

// The most recent error message set by any call on the calling thread
// (thread-local, mirroring slvs's own convention where handle-returning
// calls use a 0/nullptr sentinel instead of a real exception) - valid until
// the next occt_* call on this thread. Never null; empty string if nothing
// has failed yet.
DIDSA_OCCT_API const char* occt_last_error();

// -1 on failure (doc is null, or GetFreeShapes threw) - a real document
// always has count >= 0, so -1 is a safe, unambiguous sentinel distinct from
// "zero bodies" (a STEP file with no free shapes at all - unusual, but not
// itself invalid).
DIDSA_OCCT_API int32_t occt_document_body_count(OcctDocumentHandle doc);

// The body's own XCAF label name (TDataStd_Name via TDF_Label::GetLabelName
// in the pythonocc-core binding this shim's C++ API mirrors), or an empty
// string if the label has no name at all - the Dart side synthesizes
// "Body N" in that case (see step_loader.dart's MeshBody), rather than this
// shim inventing a name of its own. Returns "" (never nullptr) for an
// out-of-range [index] too, alongside a occt_last_error message - callers
// are expected to have already checked [index] against
// occt_document_body_count.
DIDSA_OCCT_API const char* occt_document_body_name(OcctDocumentHandle doc, int32_t index);

// Fills out_min/out_max (each a 3-element double array: x, y, z) with
// [index]'s own axis-aligned bounding box, computed via BRepBndLib::Add +
// Bnd_Box - cheap relative to full tessellation, which is exactly why this
// is exposed as its own call: the Dart loader uses every body's bbox (before
// any tessellation happens at all) both to compute the whole assembly's
// bbox-diagonal-based linear deflection (see step_loader.dart's
// StepTessellationQuality) and for ray-vs-AABB broad-phase tap-to-hide
// hit-testing. Returns 0 on success, non-zero (with occt_last_error set) on
// failure (bad doc/index, or a degenerate/empty shape with no real bbox).
DIDSA_OCCT_API int32_t occt_document_body_bbox(
    OcctDocumentHandle doc, int32_t index, double* out_min, double* out_max);

// Tessellates body [index] via BRepMesh_IncrementalMesh(shape,
// linear_deflection, /*isRelative=*/false, angular_deflection_radians,
// /*isInParallel=*/true) - mirrors backend/app/document/mesh.py's
// tessellate_shape call exactly (same 5 positional arguments, same meaning) -
// then walks every face's TopLoc_Location + BRep_Tool::Triangulation,
// de-indexing into a flat triangle soup (one fresh position+normal per
// vertex per triangle - matches DecodedMesh's layout; see
// occt_tessellation_copy_positions/_normals). Returns nullptr (with
// occt_last_error set) on failure - a bad doc/index, a shape with no
// triangulatable geometry, or an unhandled OCCT exception.
DIDSA_OCCT_API OcctTessellationHandle occt_tessellate_body(
    OcctDocumentHandle doc, int32_t index, double linear_deflection, double angular_deflection_radians);

// -1 on a null/invalid handle.
DIDSA_OCCT_API int32_t occt_tessellation_triangle_count(OcctTessellationHandle tessellation);

// Copies triangle_count * 9 doubles (3 vertices/triangle * 3 components) into
// caller-owned [out] - the caller (step_loader.dart's isolate) allocates
// exactly `occt_tessellation_triangle_count(tessellation) * 9` doubles via
// Float64List/Pointer<Double>, converting down to Float32List only after
// this copy (OCCT geometry is double precision throughout; narrowing to
// float32 is a deliberate Dart-side choice, not something this shim does,
// so nothing here silently loses precision the caller didn't ask for).
// Returns 0 on success, non-zero on a null handle/null out pointer.
DIDSA_OCCT_API int32_t occt_tessellation_copy_positions(OcctTessellationHandle tessellation, double* out);

// Same contract as occt_tessellation_copy_positions, for per-vertex normals
// (flat-shaded: every vertex of a given triangle shares that triangle's own
// face normal, matching tessellate_shape's own "each triangle gets its own 3
// fresh vertices... no cross-triangle vertex averaging" convention).
DIDSA_OCCT_API int32_t occt_tessellation_copy_normals(OcctTessellationHandle tessellation, double* out);

DIDSA_OCCT_API void occt_tessellation_destroy(OcctTessellationHandle tessellation);

}  // extern "C"

#endif  // DIDSA_OCCT_FFI_SHIM_H
