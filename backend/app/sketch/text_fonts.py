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
# see each font's own fonts/OFL-<name>.txt (all SIL OFL 1.1, from Google's
# own github.com/google/fonts, which explicitly permits bundling/
# redistribution - the license text is identical across fonts, but the
# copyright/attribution notice at the top of each one is font-specific, so
# each font keeps its own copy rather than sharing a single file).
#
# Feedback round: expanded from Open Sans alone to a small set spanning
# different registers a mechanical/engineering drawing might reasonably
# want - a second humanist sans (Lato) and a third, more geometric one
# (Fira Sans), a serif (IBM Plex Serif), two monospace options for
# tabular/dimension-style labeling (IBM Plex Mono, Space Mono), a
# condensed technical/display face (Rajdhani), and Roboto itself (the
# de facto default modern UI sans, included both for its own sake and
# because it's the one non-static variable font here - see the comment on
# its own dict entry below - so it doubles as a smoke test that OCCT's
# font-to-BRep path handles a variable font's default/Regular named
# instance correctly, not just single-weight static files like every
# other entry).
FONT_ALLOWLIST: dict[str, str] = {
    "Open Sans": "OpenSans-Regular.ttf",
    "Roboto": "Roboto-Regular.ttf",
    "Lato": "Lato-Regular.ttf",
    "Fira Sans": "FiraSans-Regular.ttf",
    "IBM Plex Serif": "IBMPlexSerif-Regular.ttf",
    "IBM Plex Mono": "IBMPlexMono-Regular.ttf",
    "Space Mono": "SpaceMono-Regular.ttf",
    "Rajdhani": "Rajdhani-Regular.ttf",
}

DEFAULT_FONT = "Open Sans"
