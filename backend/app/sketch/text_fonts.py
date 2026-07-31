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
#
# 3D-viewport Text tool round (`docs/text-tool-3d-viewport-scope.md` §2.2):
# widened from 8 to 20, adding "simple," "technical," and "decorative"
# registers a nameplate/enclosure-label/engraving use case would
# reasonably want, beyond the original mechanical-drawing-label set above.
# Every new entry is a genuinely static single-weight font file (unlike
# Roboto above, current upstream `google/fonts` now ships several
# once-static families - Inter, Work Sans, Oswald, Cinzel, Playfair
# Display among them - as variable-only, with no `static/` fallback
# folder any more; those were deliberately passed over here rather than
# adding more variable-font surface than the one Roboto already
# exercises as its own smoke test) - confirmed per-file via direct
# `google/fonts` `METADATA.pb` inspection before fetching, not assumed
# from the family name alone. All twelve are SIL OFL 1.1 licensed, same
# terms as the original eight, each with its own copyright-notice-
# specific `fonts/OFL-<name>.txt` copy (see the module-level comment
# above for why one file isn't shared across all of them).
#
# Deliberately excludes connected-script/handwriting faces (Pacifico,
# Dancing Script, and the like) from the decorative set: those are
# designed for glyphs to visually overlap/join, which is exactly the
# shape most likely to produce a self-intersecting or impractically thin
# (paper-thin extrude wall) outline rather than the clean closed profile
# per glyph `text_geometry.py` needs - see that module's own docstring
# for what OCCT's `text_to_brep` has actually been confirmed to produce
# (one correctly-holed Face per glyph) for every font tested so far, all
# of them well-behaved sans/serif/slab/display faces.
#
# Important caveat, carried over rather than silently assumed away: this
# project's sandbox has never had `pythonocc-core` installed (confirmed
# again for this round - `import OCC` still fails here), so none of the
# twelve new entries below have been run through the same direct
# `text_to_polygons`-then-inspect on-device check the original eight
# (particularly Roboto, §1's own variable-font smoke test) already had.
# They were chosen conservatively specifically to minimize that risk
# (bold/geometric decorative faces over thin/connected ones, verified-
# static files only), but a real on-device spot-check before this list
# is fully trusted in production - the same check `docs/sketcher-
# overhaul-scope.md` §6.2.6 originally ran before any Text work shipped
# at all - is still a real, not-yet-closed follow-up.
FONT_ALLOWLIST: dict[str, str] = {
    # Simple / general-purpose
    "Open Sans": "OpenSans-Regular.ttf",
    "Roboto": "Roboto-Regular.ttf",
    "Lato": "Lato-Regular.ttf",
    "Fira Sans": "FiraSans-Regular.ttf",
    "Barlow": "Barlow-Regular.ttf",
    "PT Sans": "PTSans-Regular.ttf",
    # Technical / engineering-drawing register
    "IBM Plex Serif": "IBMPlexSerif-Regular.ttf",
    "IBM Plex Mono": "IBMPlexMono-Regular.ttf",
    "Space Mono": "SpaceMono-Regular.ttf",
    "Rajdhani": "Rajdhani-Regular.ttf",
    "Barlow Condensed": "BarlowCondensed-Regular.ttf",
    "Aldrich": "Aldrich-Regular.ttf",
    "Michroma": "Michroma-Regular.ttf",
    "Audiowide": "Audiowide-Regular.ttf",
    "Arvo": "Arvo-Regular.ttf",
    "Zilla Slab": "ZillaSlab-Regular.ttf",
    # Decorative / display
    "Bebas Neue": "BebasNeue-Regular.ttf",
    "Bungee": "Bungee-Regular.ttf",
    "Abril Fatface": "AbrilFatface-Regular.ttf",
    "Marcellus": "Marcellus-Regular.ttf",
}

DEFAULT_FONT = "Open Sans"
