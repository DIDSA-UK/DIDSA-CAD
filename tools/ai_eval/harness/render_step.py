"""Line drawing of a STEP file (an assembly's export): the backend's own render-back renderer
(app.document.line_drawing: 3rd-angle front/top/right plus isometric, hidden edges dashed) applied to every solid.
Run with the backend's conda python. Usage: render_step.py model.step out.png"""
import os
import sys

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "..", "backend"))

from OCC.Core.STEPControl import STEPControl_Reader  # noqa: E402
from OCC.Core.TopAbs import TopAbs_SOLID  # noqa: E402
from OCC.Core.TopExp import TopExp_Explorer  # noqa: E402

from app.document.line_drawing import render_line_drawing  # noqa: E402

reader = STEPControl_Reader()
if reader.ReadFile(sys.argv[1]) != 1:
    sys.exit("STEP read failed")
reader.TransferRoots()
shape = reader.OneShape()
solids = []
e = TopExp_Explorer(shape, TopAbs_SOLID)
while e.More():
    solids.append(e.Current())
    e.Next()
open(sys.argv[2], "wb").write(render_line_drawing(solids or [shape]))
