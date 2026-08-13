import subprocess
from pathlib import Path

from fastapi import Depends, FastAPI
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.auth import verify_api_key
from app.document.router import router as document_router
from app.sketch.router import router as sketch_router

# Applied at the app level (not per-router) so every route - including
# /health - requires the API key. /health is included deliberately:
# Cloudflare Tunnel makes this container internet-reachable with no auth of
# its own, and there's no separate uptime-monitoring integration that needs
# unauthenticated access yet, so leaving a working, unauthenticated endpoint
# up would both contradict "every endpoint" and let any scanner confirm the
# server is alive. Note this doesn't cover the auto-generated /docs and
# /openapi.json routes - FastAPI wires those up outside the normal
# dependency system, so they stay reachable (schema only, no data).
app = FastAPI(dependencies=[Depends(verify_api_key)])
app.include_router(sketch_router)
app.include_router(document_router)

_REPO_ROOT = Path(__file__).resolve().parent.parent.parent


def _read_git_branch() -> str:
    # Read once at import time (like app.auth's API key), not per-request -
    # the branch a running server is on doesn't change without a restart,
    # so there's no reason to shell out to git on every /health call. Used
    # by the Server Management screen's status pane to show which branch
    # the backend it's actually talking to is running, without needing a
    # separate Termux RUN_COMMAND round trip just to read a git ref -
    # informational only, so any failure here (git missing, not a repo)
    # falls back to "unknown" rather than affecting startup at all.
    try:
        result = subprocess.run(
            ["git", "rev-parse", "--abbrev-ref", "HEAD"],
            cwd=_REPO_ROOT,
            capture_output=True,
            text=True,
            timeout=5,
            check=True,
        )
        return result.stdout.strip() or "unknown"
    except Exception:
        return "unknown"


_GIT_BRANCH = _read_git_branch()


@app.get("/health")
def health() -> dict:
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    return {"status": "ok", "occt_shape_valid": not box.IsNull(), "git_branch": _GIT_BRANCH}
