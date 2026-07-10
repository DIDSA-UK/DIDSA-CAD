"""The Text tool's font allowlist (see docs/sketcher-overhaul-scope.md
6.2.6) - deliberately its own tiny, OCCT-free module. Every other file in
`app.sketch` (models/schemas/router/profile) imports nothing from OCCT at
all - a layering boundary `app.document.extrude`'s own docstring documents
from the other side ("Knows nothing about Sketch internals..."). Only the
actual `text_to_brep` conversion genuinely needs OCCT (see
`app.sketch.text_geometry`), so the font allowlist used for validation in
`schemas.py`/`models.py` lives here instead, keeping everything except that
one real OCCT touchpoint import-clean.
"""

# v1: a small backend-bundled allowlist, not arbitrary system/uploaded
# fonts - sidesteps a font-management UI and per-font licensing surface
# entirely. Every bundled font file's license must permit redistribution -
# see fonts/OFL.txt (Open Sans is SIL OFL 1.1, which explicitly permits
# bundling/redistribution).
FONT_ALLOWLIST: dict[str, str] = {
    "Open Sans": "OpenSans-Regular.ttf",
}

DEFAULT_FONT = "Open Sans"
