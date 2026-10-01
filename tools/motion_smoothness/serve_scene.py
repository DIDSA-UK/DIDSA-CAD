"""Serves ONE named multi-part scene from `backend/tests/motion_scenes.py` on 127.0.0.1:8000 (real FastAPI app, real OCCT +
py-slvs) and writes a manifest for `client/test/constrained_drag_smoothness_test.dart`.

    cd backend && python ../tools/motion_smoothness/serve_scene.py SCENE VARIANT MANIFEST
SCENE = bolt | hinge, VARIANT = floating (nothing fixed) | fixed (the scene's `base` occurrence fixed)."""
import json
import os
import sys
import threading
import time

sys.path.insert(0, os.getcwd())
import tests.conftest  # noqa: F401  (sets CAD_API_KEY = "test-api-key")
import uvicorn
from app.main import app
from tests import motion_scenes
from tests.test_assembly_solver import client

scene, variant, manifest = sys.argv[1:4]
root, roles = getattr(motion_scenes, f"{scene}_scene")()
if variant == "fixed":
    motion_scenes.fix(root, roles["base"])
json.dump({"root": root, "roles": roles, "key": "test-api-key", "scene": scene, "variant": variant,
           "occurrences": client.get(f"/document/parts/{root}/occurrences").json()}, open(manifest, "w"))
threading.Thread(target=uvicorn.Server(uvicorn.Config(app, host="127.0.0.1", port=8000, log_level="warning")).run, daemon=True).start()
print("READY", scene, variant, flush=True)
while True:
    time.sleep(1)
