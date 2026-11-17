"""A redundant constraint must not make an under-constrained Sketch read as fully constrained.

Bug report (Component 2): an L-shaped profile with every edge Horizontal/Vertical and a single LineDistance dimension showed
green. The LineDistance's companion Parallel, between two lines already Vertical, is one redundant equation; py-slvs then
returns a non-zero result, the residual check correctly accepts the solve, but its `Dof` read 0 for a sketch with 3 free
dimensions (width, height, step)."""

import copy

from app.document.native_format import sketch_from_dict
from app.sketch.solver import solve_sketch

_PTS = {
    "o": (0.0, 0.0),
    "p0": (0.0, 0.0),
    "p1": (0.0, 15.0),
    "p2": (12.0, 15.0),
    "p3": (12.0, 11.0),
    "p4": (9.0, 11.0),
    "p5": (9.0, 0.0),
}
_LINES = [("l0", "p0", "p1"), ("l1", "p1", "p2"), ("l2", "p2", "p3"), ("l3", "p3", "p4"), ("l4", "p4", "p5"), ("l5", "p5", "p0")]


def _l_profile() -> dict:
    hv = {"l0": "vertical", "l1": "horizontal", "l2": "vertical", "l3": "horizontal", "l4": "vertical", "l5": "horizontal"}
    constraints = [{"id": "c-origin", "point_a_id": "p0", "point_b_id": "o", "type": "coincident"}]
    for line_id, a, b in _LINES:
        constraints.append({"id": f"c-{line_id}", "line_id": line_id, "point_a_id": a, "point_b_id": b, "type": hv[line_id]})
    pair = {"line1_id": "l4", "line2_id": "l0", "line1_start_id": "p4", "line1_end_id": "p5", "line2_start_id": "p0", "line2_end_id": "p1"}
    constraints.append({"id": "c-dist", "distance": 9.0, "type": "line_distance", **pair})
    constraints.append({"id": "c-par", "type": "parallel", **pair})
    return {
        "id": "s",
        "plane": "YZ",
        "origin_point_id": "o",
        "flip": False,
        "rotation_quarter_turns": 0,
        "points": [{"id": k, "x": x, "y": y} for k, (x, y) in _PTS.items()],
        "entities": [
            {"type": "line", "id": i, "construction": False, "start_point_id": a, "end_point_id": b} for i, a, b in _LINES
        ],
        "constraints": constraints,
        "external_references": [],
        "pattern_instances": [],
        "mirror_instances": [],
    }


def _distance(cid: str, a: str, b: str, value: float) -> dict:
    return {"id": cid, "point_a_id": a, "point_b_id": b, "distance": value, "orientation": "linear", "provisional": False, "type": "distance"}


def test_redundant_parallel_does_not_report_fully_constrained():
    result = solve_sketch(sketch_from_dict(_l_profile()))
    assert result.converged
    assert result.dof > 0


def test_becomes_fully_constrained_only_with_the_last_dimension():
    data = _l_profile()
    extra = [_distance("d1", "p0", "p1", 15.0), _distance("d2", "p1", "p2", 12.0), _distance("d3", "p2", "p3", 4.0)]
    for n, constraint in enumerate(extra):
        data["constraints"].append(constraint)
        result = solve_sketch(sketch_from_dict(copy.deepcopy(data)))
        assert result.converged
        if n < len(extra) - 1:
            assert result.dof > 0, f"after {n + 1} of {len(extra)} dimensions"
        else:
            assert result.dof <= 0
