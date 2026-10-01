"""Backend for the headless GUI harness (see README.md): serves the real FastAPI app on 127.0.0.1:8000 with every
client sharing ONE document session, and builds a floating bolt + plate assembly on demand.

Run from backend/ in the didsa-backend env:
    LIVE_ONE_SESSION=1 python ../tools/gui_harness/gui_server.py WORK_DIR
Then, once the app has opened a 3D part (its root part exists in the shared session), `touch WORK_DIR/inject`: the
server composes plate-with-hole + bolt onto that root part (concentric + coincident mates, nothing fixed) and writes
the root part id to WORK_DIR/injected.
"""
import os
import sys
import threading
import time

sys.path.insert(0, os.getcwd())
import tests.conftest  # noqa: F401  (sets CAD_API_KEY = "test-api-key" before the app imports)
import uvicorn
from app.document.store import get_document
from app.main import app
import app.session_context as session_context
from tests import test_assembly_group as g
from tests.test_assembly_solver import _add_point, _make_box_part, _make_cylinder_part, client

work = sys.argv[1]
os.makedirs(work, exist_ok=True)

if os.environ.get("LIVE_ONE_SESSION"):
    _orig = session_context.set_current_session_id
    session_context.set_current_session_id = lambda sid: _orig(None)  # the app and this script share the default session


def inject_bolt() -> str:
    root = {"id": list(get_document().parts)[0]}
    plate = _make_box_part("Plate", size=60.0, depth=10.0)
    sf = client.post(f"/document/parts/{plate['id']}/features/sketch", json={"plane": "XY"}).json()
    c = _add_point(sf["sketch_id"], 30.0, 30.0)
    client.post(f"/sketch/sketches/{sf['sketch_id']}/circles", json={"center_point_id": c["id"], "radius": 5.0, "angle": 0.0})
    client.post(f"/document/parts/{plate['id']}/extrude-features", json={
        "sketch_feature_id": sf["id"], "extrude_type": "cut", "start_distance": 0.0, "end_distance": 10.0, "target_body_ids": [plate["body_id"]]})
    bolt = _make_cylinder_part("Bolt", radius=4.0, depth=20.0)
    rid = g._compose(root, [("occ-plate", plate, (0, 0, 0)), ("occ-bolt", bolt, (30, 30, 10))])
    g._mate(rid, "concentric", "occ-bolt", g._cyl(bolt), "occ-plate", g._cyl(plate))
    g._mate(rid, "coincident", "occ-bolt", g._face(bolt, (0, 0, -1)), "occ-plate", g._face(plate, (0, 0, 1)))
    return rid


def watch() -> None:
    flag, done = os.path.join(work, "inject"), os.path.join(work, "injected")
    while True:
        time.sleep(0.5)
        if not os.path.exists(flag) or not get_document().parts:
            continue  # nothing asked for, or the app has not opened a part yet (retry until it has)
        os.remove(flag)
        try:
            rid = inject_bolt()  # build first: the file appearing means the scene is ready
            open(done, "w").write(rid)
        except Exception:  # keep the watcher alive; the traceback is in server.log
            import traceback
            traceback.print_exc()


threading.Thread(target=watch, daemon=True).start()
threading.Thread(target=uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8000, log_level="warning")).run, daemon=True).start()
print("READY", flush=True)
while True:
    time.sleep(1)
