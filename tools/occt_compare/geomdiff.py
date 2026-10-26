"""pytest plugin: after every feature step, record each body's mass properties, bounding box, topology counts and validity.

Keyed by (test node id, nth step in that test, nth body in that step) so two runs on different kernels can be diffed.
Output: one JSONL per xdist worker in $GEOMDIFF_OUT.
"""
import json
import os
import time

import pytest

_counters: dict[str, int] = {}
_fh = None


def _props(shape):
    from OCC.Core.BRepCheck import BRepCheck_Analyzer
    from OCC.Core.BRepGProp import brepgprop
    from OCC.Core.GProp import GProp_GProps
    from OCC.Core.TopAbs import TopAbs_EDGE, TopAbs_FACE, TopAbs_SOLID, TopAbs_VERTEX
    from OCC.Core.TopExp import TopExp_Explorer
    from OCC.Core.TopTools import TopTools_IndexedMapOfShape
    from OCC.Core.TopExp import topexp

    out = {}
    vol = GProp_GProps()
    # Adaptive integration: the default Gauss order is only ~1% accurate on a few-knot B-spline face.
    brepgprop.VolumeProperties(shape, vol, 1e-6)
    area = GProp_GProps()
    brepgprop.SurfaceProperties(shape, area, 1e-6)
    c = vol.CentreOfMass()
    out["volume"] = vol.Mass()
    out["area"] = area.Mass()
    out["centroid"] = [c.X(), c.Y(), c.Z()]
    for name, kind in (("solids", TopAbs_SOLID), ("faces", TopAbs_FACE), ("edges", TopAbs_EDGE), ("vertices", TopAbs_VERTEX)):
        m = TopTools_IndexedMapOfShape()
        topexp.MapShapes(shape, kind, m)
        out[name] = m.Size()
    out["valid"] = bool(BRepCheck_Analyzer(shape).IsValid())
    return out


def _install():
    from app.document import extrude

    original = extrude._apply_feature_to_bodies

    def wrapped(feature, part, bodies, *args, **kwargs):
        started = time.perf_counter()
        result = original(feature, part, bodies, *args, **kwargs)
        seconds = time.perf_counter() - started
        node = os.environ.get("PYTEST_CURRENT_TEST", "?").rsplit(" ", 1)[0]
        step = _counters.get(node, 0)
        _counters[node] = step + 1
        for index, (body_id, shape) in enumerate(list(bodies.items())):
            record = {"test": node, "step": step, "body": index, "feature": type(feature).__name__, "seconds": seconds}
            try:
                if shape is None or shape.IsNull():
                    record["null"] = True
                else:
                    record.update(_props(shape))
            except Exception as error:  # a probe failure must never change the test's own outcome
                record["probe_error"] = repr(error)[:200]
            _fh.write(json.dumps(record) + "\n")
        return result

    extrude._apply_feature_to_bodies = wrapped


def pytest_configure(config):
    global _fh
    worker = os.environ.get("PYTEST_XDIST_WORKER", "main")
    out_dir = os.environ["GEOMDIFF_OUT"]
    os.makedirs(out_dir, exist_ok=True)
    _fh = open(os.path.join(out_dir, f"{worker}.jsonl"), "a", buffering=1)
    _install()
