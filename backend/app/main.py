from fastapi import FastAPI
from OCC.Core.BRepPrimAPI import BRepPrimAPI_MakeBox

app = FastAPI()


@app.get("/health")
def health() -> dict:
    box = BRepPrimAPI_MakeBox(10.0, 10.0, 10.0).Shape()
    return {"status": "ok", "occt_shape_valid": not box.IsNull()}
