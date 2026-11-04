"""Which way a planar face really faces.

A planar face's outward normal used to be taken as its plane's axis, reversed when the face is REVERSED. That holds
for an extruded face but not for every face: the flat faces a Revolve makes lie on surfaces of revolution the
adaptor reports as planes, and the plane's axis then has no fixed relation to the face's orientation - every flat
face of a revolved pin read as facing +z, so a mate's face selector could not find its shoulder and the solver
could not seat it (found by the AI-eval assembly runs). The face's own surface derivatives (`BRepGProp_Face.Normal`)
account for its orientation, so they decide the sign."""
from OCC.Core.BRepAdaptor import BRepAdaptor_Surface
from OCC.Core.BRepGProp import BRepGProp_Face
from OCC.Core.gp import gp_Pnt, gp_Vec
from OCC.Core.TopAbs import TopAbs_REVERSED


def plane_axis_points_inward(face) -> bool:
    """True when `face`'s outward normal is the reverse of its plane's axis. `face` must be planar."""
    surface = BRepAdaptor_Surface(face, True)
    axis = surface.Plane().Axis().Direction()
    u = (surface.FirstUParameter() + surface.LastUParameter()) / 2
    v = (surface.FirstVParameter() + surface.LastVParameter()) / 2
    point, normal = gp_Pnt(), gp_Vec()
    BRepGProp_Face(face).Normal(u, v, point, normal)
    if normal.Magnitude() < 1e-12:
        return face.Orientation() == TopAbs_REVERSED
    return normal.X() * axis.X() + normal.Y() * axis.Y() + normal.Z() * axis.Z() < 0
