// Production dart:ffi shim over the SolveSpace fork's System C++ class
// (client/native/slvs/vendor/src/swig/slvs_swig.hpp). One thin extern "C"
// forwarding function per System method backend/app/sketch/solver.py and
// constraints.py actually call (see docs/sketcher-spikes-ffi-and-plane-
// sketch.md's Track 1 verdict for how this set was derived) - this is not
// the full System API.
//
// Every function catches at the C boundary: a C++ exception must never
// unwind across dart:ffi (undefined behaviour at best, a crash at worst -
// the spike's own documented finding). Handle-returning functions return 0
// on failure (System's handles are always >= 1, so 0 is a safe sentinel);
// slvs_solve returns -1 on an unexpected C++ exception, outside the normal
// [0,5] py-slvs result-code range.
#ifndef DIDSA_SLVS_FFI_SHIM_H
#define DIDSA_SLVS_FFI_SHIM_H

#include <stdint.h>

// Unlike an ELF .so (Android's actual target), a Windows DLL doesn't export
// non-static symbols by default - dart:ffi's DynamicLibrary.lookup would
// fail to find any of these otherwise. Only matters for the host desktop
// build (Milestone B's parity harness); a plain default-visibility
// extern "C" symbol is already exported on every ELF target.
#if defined(_WIN32)
#define DIDSA_SLVS_API __declspec(dllexport)
#else
#define DIDSA_SLVS_API __attribute__((visibility("default")))
#endif

extern "C" {

typedef uint32_t Slvs_hParam;
typedef uint32_t Slvs_hEntity;
typedef uint32_t Slvs_hConstraint;
typedef uint32_t Slvs_hGroup;

// Opaque handle to one System instance - create/destroy own its lifetime.
// Never persisted across solves on the Dart side (mirrors solver.py's own
// "rebuilt fresh from Points every call" design - see solver.py's
// _solve_sketch_once doc comment).
typedef void* SlvsSystemHandle;

DIDSA_SLVS_API SlvsSystemHandle slvs_system_create();
DIDSA_SLVS_API void slvs_system_destroy(SlvsSystemHandle sys);
DIDSA_SLVS_API void slvs_system_reset(SlvsSystemHandle sys);

// --- Params / entities used to build points, lines, workplane ----------

DIDSA_SLVS_API Slvs_hParam slvs_add_param_v(SlvsSystemHandle sys, double val, Slvs_hGroup group);

DIDSA_SLVS_API Slvs_hEntity slvs_add_point2d(SlvsSystemHandle sys, Slvs_hEntity wrkpln, Slvs_hParam u,
                                              Slvs_hParam v, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hEntity slvs_add_point3d_v(SlvsSystemHandle sys, double x, double y, double z,
                                                Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hEntity slvs_add_normal3d_v(SlvsSystemHandle sys, double qw, double qx, double qy, double qz,
                                                 Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hEntity slvs_add_workplane(SlvsSystemHandle sys, Slvs_hEntity origin, Slvs_hEntity normal,
                                                Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hEntity slvs_add_line_segment(SlvsSystemHandle sys, Slvs_hEntity p1, Slvs_hEntity p2,
                                                   Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hEntity slvs_add_cubic(SlvsSystemHandle sys, Slvs_hEntity wrkpln, Slvs_hEntity p1,
                                            Slvs_hEntity p2, Slvs_hEntity p3, Slvs_hEntity p4, Slvs_hGroup group);

// --- Constraints (one per SolverBuilder method in constraints.py) -------

DIDSA_SLVS_API Slvs_hConstraint slvs_add_points_distance(SlvsSystemHandle sys, double d, Slvs_hEntity p1,
                                                           Slvs_hEntity p2, Slvs_hEntity wrkpln,
                                                           Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_points_project_distance(SlvsSystemHandle sys, double d, Slvs_hEntity p1,
                                                                   Slvs_hEntity p2, Slvs_hEntity line,
                                                                   Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_points_vertical(SlvsSystemHandle sys, Slvs_hEntity p1, Slvs_hEntity p2,
                                                           Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_points_horizontal(SlvsSystemHandle sys, Slvs_hEntity p1, Slvs_hEntity p2,
                                                             Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_curves_tangent(SlvsSystemHandle sys, int at_end1, int at_end2,
                                                          Slvs_hEntity c1, Slvs_hEntity c2, Slvs_hEntity wrkpln,
                                                          Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_angle(SlvsSystemHandle sys, double degrees, int supplement,
                                                Slvs_hEntity l1, Slvs_hEntity l2, Slvs_hEntity wrkpln,
                                                Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_points_coincident(SlvsSystemHandle sys, Slvs_hEntity p1,
                                                             Slvs_hEntity p2, Slvs_hEntity wrkpln,
                                                             Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_parallel(SlvsSystemHandle sys, Slvs_hEntity l1, Slvs_hEntity l2,
                                                    Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_perpendicular(SlvsSystemHandle sys, Slvs_hEntity l1, Slvs_hEntity l2,
                                                         Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_equal_length(SlvsSystemHandle sys, Slvs_hEntity l1, Slvs_hEntity l2,
                                                        Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_equal_length_point_line_distance(SlvsSystemHandle sys, Slvs_hEntity pt,
                                                                           Slvs_hEntity l1, Slvs_hEntity l2,
                                                                           Slvs_hEntity wrkpln,
                                                                           Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_point_on_line(SlvsSystemHandle sys, Slvs_hEntity pt, Slvs_hEntity line,
                                                         Slvs_hEntity wrkpln, Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_point_line_distance(SlvsSystemHandle sys, double d, Slvs_hEntity pt,
                                                               Slvs_hEntity line, Slvs_hEntity wrkpln,
                                                               Slvs_hGroup group);
DIDSA_SLVS_API Slvs_hConstraint slvs_add_mid_point(SlvsSystemHandle sys, Slvs_hEntity pt, Slvs_hEntity line,
                                                     Slvs_hEntity wrkpln, Slvs_hGroup group);

// --- Solve + readback -----------------------------------------------------

// Returns py-slvs's raw result code (0 = success, 4/5 = redundant-but-
// solved, per solver.py's own REDUNDANT_OK handling), or -1 if an
// unexpected C++ exception was caught at this boundary.
DIDSA_SLVS_API int slvs_solve(SlvsSystemHandle sys, Slvs_hGroup group, int report_failed);

DIDSA_SLVS_API int slvs_get_dof(SlvsSystemHandle sys);
DIDSA_SLVS_API int slvs_get_failed_count(SlvsSystemHandle sys);
DIDSA_SLVS_API Slvs_hConstraint slvs_get_failed_at(SlvsSystemHandle sys, int index);
DIDSA_SLVS_API Slvs_hParam slvs_get_entity_param(SlvsSystemHandle sys, Slvs_hEntity entity, int idx);
DIDSA_SLVS_API double slvs_get_param_value(SlvsSystemHandle sys, Slvs_hParam param);

}  // extern "C"

#endif  // DIDSA_SLVS_FFI_SHIM_H
