// Low-level dart:ffi bindings for the didsa_slvs_ffi shared library built
// from client/native/slvs/ (see that directory's CMakeLists.txt for the
// build recipe, and slvs_ffi_shim.h for the exact C API this mirrors).
//
// This file only translates native calls into Dart function pointers - it
// has no sketch/solver domain knowledge. See solver_builder.dart for the
// [SolverBuilder] implementation built on top of it, and
// local_sketch_solver.dart for the constraint-dispatch/business-logic port
// that uses that builder.
import 'dart:ffi' as ffi;

const int slvsFixedGroup = 1;
const int slvsSolveGroup = 2;

typedef CreateNative = ffi.Pointer<ffi.Void> Function();
typedef CreateDart = ffi.Pointer<ffi.Void> Function();

typedef DestroyNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef DestroyDart = void Function(ffi.Pointer<ffi.Void>);

typedef ResetNative = ffi.Void Function(ffi.Pointer<ffi.Void>);
typedef ResetDart = void Function(ffi.Pointer<ffi.Void>);

typedef AddParamVNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32);
typedef AddParamVDart = int Function(ffi.Pointer<ffi.Void>, double, int);

typedef AddPoint2dNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPoint2dDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddPoint3dVNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Double, ffi.Double, ffi.Uint32);
typedef AddPoint3dVDart = int Function(ffi.Pointer<ffi.Void>, double, double, double, int);

typedef AddNormal3dVNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Double, ffi.Double, ffi.Double, ffi.Uint32);
typedef AddNormal3dVDart = int Function(ffi.Pointer<ffi.Void>, double, double, double, double, int);

typedef AddWorkplaneNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddWorkplaneDart = int Function(ffi.Pointer<ffi.Void>, int, int, int);

typedef AddLineSegmentNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddLineSegmentDart = int Function(ffi.Pointer<ffi.Void>, int, int, int);

typedef AddCubicNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddCubicDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int, int, int);

typedef AddPointsDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsDistanceDart = int Function(ffi.Pointer<ffi.Void>, double, int, int, int, int);

typedef AddPointsProjectDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsProjectDistanceDart = int Function(ffi.Pointer<ffi.Void>, double, int, int, int, int);

typedef AddPointsVerticalNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsVerticalDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddPointsHorizontalNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsHorizontalDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddCurvesTangentNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Int32, ffi.Int32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddCurvesTangentDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int, int, int);

typedef AddAngleNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Int32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddAngleDart = int Function(ffi.Pointer<ffi.Void>, double, int, int, int, int, int);

typedef AddPointsCoincidentNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointsCoincidentDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddParallelNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddParallelDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddPerpendicularNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPerpendicularDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddEqualLengthNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddEqualLengthDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddEqualLengthPointLineDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddEqualLengthPointLineDistanceDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int, int);

typedef AddPointOnLineNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointOnLineDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef AddPointLineDistanceNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Double, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddPointLineDistanceDart = int Function(ffi.Pointer<ffi.Void>, double, int, int, int, int);

typedef AddMidPointNative = ffi.Uint32 Function(
    ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Uint32, ffi.Uint32, ffi.Uint32);
typedef AddMidPointDart = int Function(ffi.Pointer<ffi.Void>, int, int, int, int);

typedef SolveNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32);
typedef SolveDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef GetDofNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef GetDofDart = int Function(ffi.Pointer<ffi.Void>);

typedef GetFailedCountNative = ffi.Int32 Function(ffi.Pointer<ffi.Void>);
typedef GetFailedCountDart = int Function(ffi.Pointer<ffi.Void>);

typedef GetFailedAtNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Int32);
typedef GetFailedAtDart = int Function(ffi.Pointer<ffi.Void>, int);

typedef GetEntityParamNative = ffi.Uint32 Function(ffi.Pointer<ffi.Void>, ffi.Uint32, ffi.Int32);
typedef GetEntityParamDart = int Function(ffi.Pointer<ffi.Void>, int, int);

typedef GetParamValueNative = ffi.Double Function(ffi.Pointer<ffi.Void>, ffi.Uint32);
typedef GetParamValueDart = double Function(ffi.Pointer<ffi.Void>, int);

/// One Dart function pointer per `slvs_ffi_shim.h` export - see that
/// header for the exact C signatures and the exception/sentinel-value
/// contract at the FFI boundary (0 on failure for handle-returning calls,
/// -1 from [solve] on an unexpected native exception).
class SlvsNativeBindings {
  final CreateDart create;
  final DestroyDart destroy;
  final ResetDart reset;
  final AddParamVDart addParamV;
  final AddPoint2dDart addPoint2d;
  final AddPoint3dVDart addPoint3dV;
  final AddNormal3dVDart addNormal3dV;
  final AddWorkplaneDart addWorkplane;
  final AddLineSegmentDart addLineSegment;
  final AddCubicDart addCubic;
  final AddPointsDistanceDart addPointsDistance;
  final AddPointsProjectDistanceDart addPointsProjectDistance;
  final AddPointsVerticalDart addPointsVertical;
  final AddPointsHorizontalDart addPointsHorizontal;
  final AddCurvesTangentDart addCurvesTangent;
  final AddAngleDart addAngle;
  final AddPointsCoincidentDart addPointsCoincident;
  final AddParallelDart addParallel;
  final AddPerpendicularDart addPerpendicular;
  final AddEqualLengthDart addEqualLength;
  final AddEqualLengthPointLineDistanceDart addEqualLengthPointLineDistance;
  final AddPointOnLineDart addPointOnLine;
  final AddPointLineDistanceDart addPointLineDistance;
  final AddMidPointDart addMidPoint;
  final SolveDart solve;
  final GetDofDart getDof;
  final GetFailedCountDart getFailedCount;
  final GetFailedAtDart getFailedAt;
  final GetEntityParamDart getEntityParam;
  final GetParamValueDart getParamValue;

  SlvsNativeBindings(ffi.DynamicLibrary lib)
      : create = lib.lookupFunction<CreateNative, CreateDart>('slvs_system_create'),
        destroy = lib.lookupFunction<DestroyNative, DestroyDart>('slvs_system_destroy'),
        reset = lib.lookupFunction<ResetNative, ResetDart>('slvs_system_reset'),
        addParamV = lib.lookupFunction<AddParamVNative, AddParamVDart>('slvs_add_param_v'),
        addPoint2d = lib.lookupFunction<AddPoint2dNative, AddPoint2dDart>('slvs_add_point2d'),
        addPoint3dV = lib.lookupFunction<AddPoint3dVNative, AddPoint3dVDart>('slvs_add_point3d_v'),
        addNormal3dV = lib.lookupFunction<AddNormal3dVNative, AddNormal3dVDart>('slvs_add_normal3d_v'),
        addWorkplane = lib.lookupFunction<AddWorkplaneNative, AddWorkplaneDart>('slvs_add_workplane'),
        addLineSegment = lib.lookupFunction<AddLineSegmentNative, AddLineSegmentDart>('slvs_add_line_segment'),
        addCubic = lib.lookupFunction<AddCubicNative, AddCubicDart>('slvs_add_cubic'),
        addPointsDistance =
            lib.lookupFunction<AddPointsDistanceNative, AddPointsDistanceDart>('slvs_add_points_distance'),
        addPointsProjectDistance = lib.lookupFunction<AddPointsProjectDistanceNative,
            AddPointsProjectDistanceDart>('slvs_add_points_project_distance'),
        addPointsVertical =
            lib.lookupFunction<AddPointsVerticalNative, AddPointsVerticalDart>('slvs_add_points_vertical'),
        addPointsHorizontal = lib.lookupFunction<AddPointsHorizontalNative, AddPointsHorizontalDart>(
            'slvs_add_points_horizontal'),
        addCurvesTangent =
            lib.lookupFunction<AddCurvesTangentNative, AddCurvesTangentDart>('slvs_add_curves_tangent'),
        addAngle = lib.lookupFunction<AddAngleNative, AddAngleDart>('slvs_add_angle'),
        addPointsCoincident = lib.lookupFunction<AddPointsCoincidentNative, AddPointsCoincidentDart>(
            'slvs_add_points_coincident'),
        addParallel = lib.lookupFunction<AddParallelNative, AddParallelDart>('slvs_add_parallel'),
        addPerpendicular =
            lib.lookupFunction<AddPerpendicularNative, AddPerpendicularDart>('slvs_add_perpendicular'),
        addEqualLength = lib.lookupFunction<AddEqualLengthNative, AddEqualLengthDart>('slvs_add_equal_length'),
        addEqualLengthPointLineDistance = lib.lookupFunction<AddEqualLengthPointLineDistanceNative,
            AddEqualLengthPointLineDistanceDart>('slvs_add_equal_length_point_line_distance'),
        addPointOnLine = lib.lookupFunction<AddPointOnLineNative, AddPointOnLineDart>('slvs_add_point_on_line'),
        addPointLineDistance = lib.lookupFunction<AddPointLineDistanceNative, AddPointLineDistanceDart>(
            'slvs_add_point_line_distance'),
        addMidPoint = lib.lookupFunction<AddMidPointNative, AddMidPointDart>('slvs_add_mid_point'),
        solve = lib.lookupFunction<SolveNative, SolveDart>('slvs_solve'),
        getDof = lib.lookupFunction<GetDofNative, GetDofDart>('slvs_get_dof'),
        getFailedCount = lib.lookupFunction<GetFailedCountNative, GetFailedCountDart>('slvs_get_failed_count'),
        getFailedAt = lib.lookupFunction<GetFailedAtNative, GetFailedAtDart>('slvs_get_failed_at'),
        getEntityParam =
            lib.lookupFunction<GetEntityParamNative, GetEntityParamDart>('slvs_get_entity_param'),
        getParamValue = lib.lookupFunction<GetParamValueNative, GetParamValueDart>('slvs_get_param_value');
}
