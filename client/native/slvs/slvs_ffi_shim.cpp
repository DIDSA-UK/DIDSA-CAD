#include "slvs_ffi_shim.h"

#include "slvs_swig.hpp"

namespace {
System* sys(SlvsSystemHandle handle) { return static_cast<System*>(handle); }
}  // namespace

extern "C" {

SlvsSystemHandle slvs_system_create() {
    try {
        return new System();
    } catch (...) {
        return nullptr;
    }
}

void slvs_system_destroy(SlvsSystemHandle handle) {
    delete sys(handle);
}

void slvs_system_reset(SlvsSystemHandle handle) {
    try {
        sys(handle)->reset();
    } catch (...) {
    }
}

Slvs_hParam slvs_add_param_v(SlvsSystemHandle handle, double val, Slvs_hGroup group) {
    try {
        return sys(handle)->addParamV(val, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_point2d(SlvsSystemHandle handle, Slvs_hEntity wrkpln, Slvs_hParam u, Slvs_hParam v,
                               Slvs_hGroup group) {
    try {
        return sys(handle)->addPoint2d(wrkpln, u, v, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_point3d_v(SlvsSystemHandle handle, double x, double y, double z, Slvs_hGroup group) {
    try {
        return sys(handle)->addPoint3dV(x, y, z, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_normal3d_v(SlvsSystemHandle handle, double qw, double qx, double qy, double qz,
                                  Slvs_hGroup group) {
    try {
        return sys(handle)->addNormal3dV(qw, qx, qy, qz, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_workplane(SlvsSystemHandle handle, Slvs_hEntity origin, Slvs_hEntity normal,
                                 Slvs_hGroup group) {
    try {
        return sys(handle)->addWorkplane(origin, normal, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_line_segment(SlvsSystemHandle handle, Slvs_hEntity p1, Slvs_hEntity p2, Slvs_hGroup group) {
    try {
        return sys(handle)->addLineSegment(p1, p2, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hEntity slvs_add_cubic(SlvsSystemHandle handle, Slvs_hEntity wrkpln, Slvs_hEntity p1, Slvs_hEntity p2,
                             Slvs_hEntity p3, Slvs_hEntity p4, Slvs_hGroup group) {
    try {
        return sys(handle)->addCubic(wrkpln, p1, p2, p3, p4, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_points_distance(SlvsSystemHandle handle, double d, Slvs_hEntity p1, Slvs_hEntity p2,
                                           Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointsDistance(d, p1, p2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_points_project_distance(SlvsSystemHandle handle, double d, Slvs_hEntity p1,
                                                   Slvs_hEntity p2, Slvs_hEntity line, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointsProjectDistance(d, p1, p2, line, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_points_vertical(SlvsSystemHandle handle, Slvs_hEntity p1, Slvs_hEntity p2,
                                           Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointsVertical(p1, p2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_points_horizontal(SlvsSystemHandle handle, Slvs_hEntity p1, Slvs_hEntity p2,
                                             Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointsHorizontal(p1, p2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_curves_tangent(SlvsSystemHandle handle, int at_end1, int at_end2, Slvs_hEntity c1,
                                          Slvs_hEntity c2, Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addCurvesTangent(at_end1 != 0, at_end2 != 0, c1, c2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_angle(SlvsSystemHandle handle, double degrees, int supplement, Slvs_hEntity l1,
                                 Slvs_hEntity l2, Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addAngle(degrees, supplement != 0, l1, l2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_points_coincident(SlvsSystemHandle handle, Slvs_hEntity p1, Slvs_hEntity p2,
                                             Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointsCoincident(p1, p2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_parallel(SlvsSystemHandle handle, Slvs_hEntity l1, Slvs_hEntity l2, Slvs_hEntity wrkpln,
                                    Slvs_hGroup group) {
    try {
        return sys(handle)->addParallel(l1, l2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_perpendicular(SlvsSystemHandle handle, Slvs_hEntity l1, Slvs_hEntity l2,
                                         Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPerpendicular(l1, l2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_equal_length(SlvsSystemHandle handle, Slvs_hEntity l1, Slvs_hEntity l2,
                                        Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addEqualLength(l1, l2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_equal_length_point_line_distance(SlvsSystemHandle handle, Slvs_hEntity pt,
                                                             Slvs_hEntity l1, Slvs_hEntity l2,
                                                             Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addEqualLengthPointLineDistance(pt, l1, l2, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_point_on_line(SlvsSystemHandle handle, Slvs_hEntity pt, Slvs_hEntity line,
                                         Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointOnLine(pt, line, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_point_line_distance(SlvsSystemHandle handle, double d, Slvs_hEntity pt, Slvs_hEntity line,
                                               Slvs_hEntity wrkpln, Slvs_hGroup group) {
    try {
        return sys(handle)->addPointLineDistance(d, pt, line, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_add_mid_point(SlvsSystemHandle handle, Slvs_hEntity pt, Slvs_hEntity line, Slvs_hEntity wrkpln,
                                     Slvs_hGroup group) {
    try {
        return sys(handle)->addMidPoint(pt, line, wrkpln, group);
    } catch (...) {
        return 0;
    }
}

int slvs_solve(SlvsSystemHandle handle, Slvs_hGroup group, int report_failed) {
    try {
        return sys(handle)->solve(group, report_failed != 0, false);
    } catch (...) {
        return -1;
    }
}

int slvs_get_dof(SlvsSystemHandle handle) {
    try {
        return sys(handle)->Dof;
    } catch (...) {
        return -1;
    }
}

int slvs_get_failed_count(SlvsSystemHandle handle) {
    try {
        return static_cast<int>(sys(handle)->Failed.size());
    } catch (...) {
        return 0;
    }
}

Slvs_hConstraint slvs_get_failed_at(SlvsSystemHandle handle, int index) {
    try {
        const auto& failed = sys(handle)->Failed;
        if (index < 0 || static_cast<size_t>(index) >= failed.size()) return 0;
        return failed[static_cast<size_t>(index)];
    } catch (...) {
        return 0;
    }
}

Slvs_hParam slvs_get_entity_param(SlvsSystemHandle handle, Slvs_hEntity entity, int idx) {
    try {
        return sys(handle)->getEntityParam(entity, idx);
    } catch (...) {
        return 0;
    }
}

double slvs_get_param_value(SlvsSystemHandle handle, Slvs_hParam param) {
    try {
        return sys(handle)->getParam(param).val;
    } catch (...) {
        return 0.0;
    }
}

}  // extern "C"
