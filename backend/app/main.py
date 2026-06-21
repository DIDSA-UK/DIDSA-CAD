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


@app.get("/health")
def health() -> dict:
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    return {"status": "ok", "occt_shape_valid": not box.IsNull()}
