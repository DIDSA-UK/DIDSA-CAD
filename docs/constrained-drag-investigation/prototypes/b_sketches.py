"""Scratch: build real app-style sketches with the backend's own Sketch model (imported as a library, unmodified)."""
import os, sys, copy, math, json, time
os.environ.setdefault("CAD_API_KEY", "x")
sys.path.insert(0, "/home/user/DIDSA-CAD/backend")
from app.sketch.models import Sketch, Plane
from app.sketch.solver import solve_sketch

def new():
    s = Sketch(id="s", plane=Plane.XY); s.origin_point(); return s

def rect_at(s, x0, y0, w, h):
    ps = [s.add_point(x, y) for x, y in [(x0, y0), (x0 + w, y0), (x0 + w, y0 + h), (x0, y0 + h)]]
    r = s.add_rectangle([p.id for p in ps], axis_aligned=True); return r, ps

def sk_rect_partial():          # corner on origin + width dimension; height free   -> dof 1
    s = new(); r, ps = rect_at(s, 0, 0, 40, 25)
    s.add_coincident_constraint(ps[0].id, s.origin_point_id)
    s.add_distance_constraint(ps[0].id, ps[1].id, 40.0)
    return s, ps[2].id                      # drag target: top-right corner

def sk_rect_full():             # corner on origin + width + height dimensions   -> dof 0
    s = new(); r, ps = rect_at(s, 0, 0, 40, 25)
    s.add_coincident_constraint(ps[0].id, s.origin_point_id)
    s.add_distance_constraint(ps[0].id, ps[1].id, 40.0)
    s.add_distance_constraint(ps[1].id, ps[2].id, 25.0)
    return s, ps[2].id

def sk_rect_floating():         # rectangle, no dimensions, not attached to origin -> dof 4 (x, y, w, h)
    s = new(); r, ps = rect_at(s, 10, 10, 40, 25)
    return s, ps[2].id

def sk_two_link():              # origin -L1(30)- P1 -L2(25)- P2 : 2-DOF arm
    s = new(); p1 = s.add_point(20, 20); p2 = s.add_point(35, 40)
    l1 = s.add_line(s.origin_point_id, p1.id); l2 = s.add_line(p1.id, p2.id)
    s.add_distance_constraint(s.origin_point_id, p1.id, 30.0); s.add_distance_constraint(p1.id, p2.id, 25.0)
    return s, p2.id

def sk_hexagon():               # regular polygon, provisional radius (real app structure w/ redundant chain)
    s = new(); c = s.add_point(30, 20); v = s.add_point(45, 20)
    poly = s.add_polygon(c.id, v.id, 6)
    return s, v.id

def sk_slot():
    s = new(); c1 = s.add_point(20, 20); c2 = s.add_point(50, 20)
    slot = s.add_slot(c1.id, c2.id, 5.0)
    return s, c2.id

def sk_grid(n):                 # n x n axis-aligned rectangles (own corners), each free
    s = new()
    for i in range(n):
        for j in range(n): rect_at(s, 30 * i, 30 * j, 20, 20)
    first = list(s.points.keys())[1]
    return s, first

def sk_redundant():             # rectangle + an explicitly redundant Parallel on two already-parallel edges
    s = new(); r, ps = rect_at(s, 0, 0, 40, 25)
    s.add_coincident_constraint(ps[0].id, s.origin_point_id)
    s.add_distance_constraint(ps[0].id, ps[1].id, 40.0)
    lines = [l.id for l in s.lines()]
    s.add_parallel_constraint(lines[0], lines[2])
    return s, ps[2].id

def sk_conflict():              # rectangle with conflicting width dimensions
    s = new(); r, ps = rect_at(s, 0, 0, 40, 25)
    s.add_coincident_constraint(ps[0].id, s.origin_point_id)
    s.add_distance_constraint(ps[0].id, ps[1].id, 40.0)
    s.add_distance_constraint(ps[0].id, ps[1].id, 55.0)
    return s, ps[2].id

ALL = {"rect_partial(w fixed, h free)": sk_rect_partial, "rect_full": sk_rect_full, "rect_floating": sk_rect_floating,
       "two_link_arm": sk_two_link, "hexagon(provisional)": sk_hexagon, "slot": sk_slot,
       "redundant_parallel": sk_redundant, "conflict_2_widths": sk_conflict}
