from fastapi import FastAPI
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

from app.sketch.router import router as sketch_router

app = FastAPI()
app.include_router(sketch_router)


@app.get("/health")
def health() -> dict:
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    return {"status": "ok", "occt_shape_valid": not box.IsNull()}
