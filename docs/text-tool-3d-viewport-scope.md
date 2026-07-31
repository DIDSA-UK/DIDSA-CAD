# Text tool in the 3D viewport, font selection, resizing, letter/line spacing — Scoping Document

Companion to a feature request covering: making the Text tool available
inside the 3D-embedded ("Orbit View") sketcher, a curated selection of
open-source fonts whose glyphs come out as closed profiles (suitable for
Extrude/Sweep/Revolve), interactive resizing, and adjustment of line
spacing and letter (character) spacing. Same convention as
`docs/sketcher-overhaul-scope.md`/`docs/pattern-mirror-scope.md`: broken
into workstreams against the *actual current implementation* (verified by
reading the code, not assumed), with proposed approach, affected files,
complexity/risk, and a suggested delivery order.

Backend: `backend/app/sketch/*` (`models.py`, `text_fonts.py`,
`text_geometry.py`, `profile.py`, `schemas.py`, `router.py`),
`backend/app/document/extrude.py` (`wire_for_profile`/`_text_world_transform`,
shared by Sweep/Revolve too).
Client: `client/lib/sketch/*` (2D canvas + controller + speed dial +
ribbon dialog), `client/lib/viewport3d/sketch_geometry_3d.dart`
(3D-embedded rendering).

**Status: design only for everything in this document — nothing here is
implemented yet.** This is *not* greenfield, though: Text already shipped
as a real, working v1 (`docs/sketcher-overhaul-scope.md` §6.2.6,
implemented and covered by `backend/tests/test_stage19_text.py`) — the
2D sketch canvas has a working Text tool today, with a font picker, size,
and rotation, and Extrude/Sweep/Revolve already consume Text profiles
through the exact same generic `Profile`/`wire_for_profile` path every
other closed-loop entity uses (confirmed by direct grep — `sweep.py`
and `revolve.py` both call `wire_for_profile` with no per-entity-type
branching, so nothing in this document is needed to make Sweep/Revolve
*accept* text; that already works). What's missing is narrower than "add
a text tool": 3D-embedded rendering, spacing controls, and a look at
whether the current font set holds up as "closed profiles" under the more
demanding fonts a user might reasonably ask for next.

---

## 1. Grounding: what already exists

- **`TextEntity`** (`backend/app/sketch/models.py:706-753`) — fields:
  `content: str`, `font: str`, `size: float`, `anchor_point_id: str`,
  `rotation_degrees: float = 0.0`. Deliberately *not* decomposed into
  constrainable Points/Lines (own docstring: "nobody hand-tweaks the
  curve of a single serif") — only `anchor_point_id` is a real, draggable
  Point; glyph geometry regenerates from `content`/`font`/`size`/
  `rotation_degrees` on every read. **No `letter_spacing` or
  `line_spacing` field exists.**
- **`FONT_ALLOWLIST`** (`backend/app/sketch/text_fonts.py:31-39`) — 8
  bundled, SIL OFL-1.1-licensed fonts (each with its own
  `backend/app/sketch/fonts/OFL-<name>.txt`), spanning humanist sans
  (Open Sans, Lato, Roboto), geometric sans (Fira Sans), serif (IBM Plex
  Serif), monospace (IBM Plex Mono, Space Mono), and condensed/display
  (Rajdhani). Not arbitrary uploaded fonts — a deliberate v1 choice to
  sidestep a font-management UI and per-font licensing review.
- **`text_to_shape`/`text_to_polygons`/`text_contour_wire`**
  (`backend/app/sketch/text_geometry.py`) — wrap OCCT's
  `OCC.Core.Addons.text_to_brep`. Confirmed by that module's own docstring
  (direct on-device testing already done for v1): a single `text_to_brep`
  call returns one `Face` per glyph, each already correctly holed (e.g.
  "o" → one outer wire + one inner counter wire) — **OCCT itself
  guarantees closed, holed profiles per glyph for any font it can
  rasterize outlines from**, which is every regular TrueType/OpenType
  font tested so far. `text_to_brep`'s signature only ever takes
  `(content, font, aspect, size, isCompositeCurve)` — **no kerning,
  tracking, or line-height parameter exists at this layer**; multi-glyph
  layout (advance widths, line breaks) is entirely OCCT's own internal
  behavior today, not something this codebase currently controls.
- **`_text_profile`** (`backend/app/sketch/profile.py:602+`) turns each
  glyph contour into its own `Profile` (outer + holes), reusing the
  existing nested-loop classification built for "a plate with a round
  hole" — already generalizes to "an 'o' is a ring with a hole," "an 'i'
  is two disjoint loops." A whole Text entity becomes a `MultiProfile` of
  N per-glyph loops.
  `app.document.extrude.wire_for_profile` (`extrude.py:234`) and
  `_text_world_transform` (`extrude.py:162`) place those loops in world
  space from the anchor Point + Sketch plane basis + `rotation_degrees` —
  generic from there on, which is exactly why Sweep/Revolve already work
  with no Text-specific code of their own (§ above).
- **2D client (`client/lib/sketch/`)**: `SketchTool.text` exists end to
  end — placement (tap to set the anchor Point), an "Edit Text" dialog
  (`sketch_ribbon.dart:621-745`) with **Content, Font (dropdown over
  `textFontOptions`, mirrored from the backend allowlist), Size, and
  Rotation** fields only, and a cached preview-outline fetch
  (`SketchController._refreshTextPreview`, per the backend's
  preview-tessellation endpoint) rendered with the same fill/stroke code
  path as every other profile. Content is a single-line `TextField`
  (`sketch_ribbon.dart:691-700`) — multi-line entry has no UI today, and
  §6.2.6's own "explicit v1 non-goals" listed "multi-line text/wrapping"
  and "per-character kerning controls beyond the font's own defaults" as
  deliberately deferred.
- **3D-embedded ("Orbit View") sketcher**: **Text is the one sketch tool
  deliberately excluded here.** `SketchSpeedDial.restrictToEmbeddedTools`
  (`client/lib/sketch/sketch_speed_dial.dart:26-51`, filtered at
  `:280-282`) hides the Text entry whenever the speed dial is embedded in
  the 3D viewport, with its own doc comment stating the reason precisely:
  tap-placement (`_clickTextTool`) is a plain, already-generic handler and
  works fine in 3D, but **`sketchGeometry3DFrom`
  (`client/lib/viewport3d/sketch_geometry_3d.dart:544+`) has no Text case
  at all** — no `textPolygons`/`textIds` fields exist on
  `SketchGeometry3D` (contrast `circlePolygons`/`arcPolylines`/
  `ellipsePolygons`/`splinePolylines`, each with a parallel id array).
  Selecting Text in Orbit View today would silently place an anchor Point
  with no visible glyph geometry. This is the concrete, scoped gap behind
  "add a text tool to the 3D viewport" — Text placement/editing/regen
  already exists; only 3D *rendering* of it doesn't.

---

## 2. Workstreams

### 2.1 Render Text in the 3D-embedded sketcher (the actual "add Text to the 3D viewport" ask)

- **Proposed approach**: give `SketchGeometry3D` a `textPolygons`/
  `textHoles`/`textIds` triple (outer loop, its holes, and the owning
  Text entity id — one entry per glyph contour, mirroring
  `circlePolygons`/`circleIds`'s own shape), populated inside
  `sketchGeometry3DFrom` from the same cached preview-outline data the 2D
  canvas already fetches and caches per Text entity
  (`SketchController._refreshTextPreview`) — **no new backend endpoint
  needed**, this reuses the existing preview-tessellation route, just
  consumed by a second renderer. `buildSketchGeometryNode` gets a new
  branch that triangulates each glyph's (outer, holes) polygon the same
  way `circlePolygons`/`ellipsePolygons` already do for fill, placed at
  the Sketch's own plane basis (the same transform every other 3D-embedded
  entity already goes through — no new placement math).
- **Sequencing dependency**: the preview cache is keyed off 2D-canvas
  lifecycle today (`SketchController` owns it regardless of which view is
  active, so this is a rendering-consumer change, not a data-plumbing
  one) — confirm the cache is populated/invalidated correctly when the 2D
  canvas is never shown during an Orbit-View-only editing session (a
  realistic path once Text is enabled there) before assuming it "just
  works."
- **Once this lands**, `restrictToEmbeddedTools`'s filter
  (`sketch_speed_dial.dart:280-282`) drops the Text exclusion — one-line
  change, gated entirely on the rendering gap above being closed first.
- **Selection/hit-testing**: out of scope for this workstream, matching
  the precedent already set for Arc/Ellipse/Spline (`sketch_geometry_3d.dart:239-243`'s
  own doc comment: rendering shipped well before selection did for those
  three). A user can place, see, and edit Text via the ribbon dialog in
  Orbit View; direct 3D tap-to-select/drag-the-anchor-Point on Text is a
  natural, separate follow-up once this lands, not a blocker for it.
- **Files**: `sketch_geometry_3d.dart` (new fields + `buildSketchGeometryNode`
  branch), `sketch_speed_dial.dart` (drop the one-line exclusion once the
  above is confirmed working on-device).
- **Risk**: low-medium. The hard part (deriving correct, holed glyph
  geometry) is already solved and cached for the 2D canvas; this is
  "consume that cache from a second renderer," not new geometry work.

### 2.2 Font selection: audit the existing allowlist as "closed profiles for Extrude/Sweep/Revolve," decide if it needs to grow

- **Current state**: 8 OFL-licensed fonts already bundled (§1), already
  confirmed to produce closed, correctly-holed per-glyph profiles via
  direct on-device OCCT testing, already extrude/sweep/revolve-able with
  zero Text-specific code in those three features. In that narrow sense,
  "a selection of open-source fonts that create closed profiles suitable
  for extrude, sweep, etc." **already exists and already works.**
- **Real open question**: is 8 fonts, spanning the registers picked for
  an "engineering drawing" use case (`text_fonts.py`'s own docstring),
  the right selection for this ask, or does "add a selection" mean
  broadening it — e.g. a display/script face for enclosures/nameplates,
  a second serif, a heavier weight per family (OCCT's `text_to_brep`
  takes a single font *file* per allowlist entry — Bold/Italic today
  would need separate allowlist entries pointing at separate `.ttf`
  files, not a variant flag on the existing ones, confirmed by
  `FONT_ALLOWLIST`'s `{name: filename}` shape). **This needs a product
  decision, not just engineering** — recommend clarifying with whoever
  requested this whether the ask is "confirm the existing set is fit for
  purpose" (near-zero work) or "add N more named fonts" (bounded, low-risk
  work: pick fonts, confirm OFL/Apache-2.0-or-equivalent redistribution
  rights, drop the `.ttf` + license file into `backend/app/sketch/fonts/`,
  add one `FONT_ALLOWLIST` entry each — the exact mechanical steps
  already used for all 8 current entries).
- **One real technical risk worth flagging, not yet checked**: every
  current font is a well-behaved Latin sans/serif/mono/display face.
  Nothing has verified `text_to_brep`'s behavior on a font with genuinely
  open/self-intersecting outline conventions (some ultra-thin hairline or
  heavily-stylized script faces do this deliberately) or a variable font
  used at an instance other than its default (the existing Roboto entry
  is deliberately the one variable-font smoke test — worth re-reading its
  own comment in `text_fonts.py` before picking a second one). Any new
  font added under this workstream should get the same direct
  `text_to_polygons`-then-inspect on-device check Roboto already got
  before being trusted, not assumed safe by font category alone.
- **Files**: `backend/app/sketch/text_fonts.py` (`FONT_ALLOWLIST` +
  `DEFAULT_FONT` if it changes), `backend/app/sketch/fonts/` (new
  `.ttf`/`OFL-<name>.txt` pairs), `client/lib/sketch/sketch_controller.dart:729`
  (`textFontOptions`, kept mirrored to the backend list by convention,
  not by any shared-source-of-truth mechanism — a manual sync point to
  remember).
- **Risk**: low. Mechanical once the font list itself is decided;
  the only real unknown is the per-font OCCT-compatibility check above,
  which is fast per font (confirmed by how Roboto's own check was done).

### 2.3 Resizing

- **Current state**: `size` already exists as a plain numeric field,
  editable via the "Edit Text" dialog's `Size` `TextField`
  (`sketch_ribbon.dart:722-731`, in mm, validated positive). This is
  "resizing" in the narrowest literal sense already.
- **Real gap, if "resizing" means interactive (not just typing a number)**:
  no drag-to-resize handle exists for Text, unlike (for example) how a
  Circle's radius or a Rectangle's corner can be dragged directly on
  canvas. Every other numeric-property edit in this app (Line length,
  Circle radius, Polygon circumradius) follows the same two-track pattern
  already: a direct-manipulation drag *and* a typed-value dialog, so
  Text having only the latter is a real, if minor, inconsistency once
  Text is elevated to a first-class 3D-viewport tool.
- **Proposed approach**: add a bounding-box corner handle (computed from
  the cached preview-outline's own extents — already fetched for
  rendering, §2.1/existing 2D path, no new geometry needed) that scales
  `size` proportionally on drag, mirroring the existing drag-to-resize
  interaction pattern (`SketchController`'s existing per-tool drag
  handlers — e.g. Circle radius drag — are the template to follow, not a
  new interaction language). Keep `size` as the one persisted field (a
  linear scale of one already-parametric value) rather than introducing
  a separate width/height pair — text does not need independent
  non-uniform scaling for this use case, and OCCT's `text_to_brep` only
  takes one size parameter regardless.
- **Files**: `sketch_canvas.dart` (2D drag handle), `sketch_geometry_3d.dart`
  /`part_viewport` hit-testing (3D drag handle, if wanted there too —
  reasonable to ship 2D-canvas resizing first and treat 3D-embedded
  interactive resize as a §2.1 selection/hit-testing follow-up rather
  than blocking this workstream on it).
- **Risk**: low for the 2D canvas (an established pattern to copy); the
  3D-embedded interactive handle is deferred by the same
  selection/hit-testing boundary §2.1 already draws.

### 2.4 Letter spacing and line spacing

This is the one workstream with genuine new backend geometry work and an
unconfirmed technical unknown — flagged plainly rather than assumed easy,
matching how §6.2.6 originally flagged the OCCT-availability check before
any Text work started.

- **Current state**: neither exists. `text_to_brep` lays out the whole
  `content` string itself, using the font's own default advance widths
  and (if `content` contains a line break — untested on-device) its own
  default line height, with **no parameter to override either**. Content
  entry is single-line UI today (§1), so line spacing has no visible
  effect to control yet regardless.
- **Line spacing — proposed approach**:
  1. Multi-line content must land first (or alongside) — extend the
     "Edit Text" dialog's `Content` field to a multi-line `TextField`
     (trivial Flutter change), and confirm on-device whether
     `text_to_brep` already honors embedded `\n` characters with a
     sensible default line height (this needs the same kind of direct
     on-device check §6.2.6 ran for OCCT availability — genuinely
     unconfirmed from reading the wrapper's own signature, which takes
     no line-height parameter at all).
  2. If `\n` already works with an acceptable default: adding a
     `line_spacing` *multiplier* field to `TextEntity` means this
     codebase must do the line splitting and vertical placement itself
     rather than delegating to `text_to_brep` — call `text_to_brep` once
     per line (each already returns correctly-holed glyph geometry per
     call, §1) and translate each line's resulting contours down by
     `line_index * font_line_height * line_spacing`, composing into one
     `TopoDS_Compound` the same shape `text_to_shape` already returns
     today. `font_line_height` itself needs a real font-metrics source —
     `OCC.Core.Addons` was confirmed to expose `text_to_brep`/
     `register_font` only (§1's own docstring); whether it also exposes
     a font-metrics query, or this needs a value derived empirically per
     bundled font (e.g. from each glyph's own bounding-box height at a
     known size) is the concrete unconfirmed unknown here, parallel to
     the original 6.2.6 "is `Font_BRepFont` reachable" check.
- **Letter (character) spacing — proposed approach**: same
  per-unit-then-recompose shape as line spacing, one level deeper — call
  `text_to_brep` once per *character* instead of once per line, and
  translate each character's contours right by a running
  `advance_so_far + (glyph_index * extra_tracking)`. This needs each
  character's own advance width, which has the same unconfirmed
  font-metrics-source gap as line height above — **and** loses whatever
  automatic kerning-pair adjustment (e.g. tighter "AV" spacing) OCCT's
  own single-string layout currently applies for free, since per-character
  calls lay out purely by advance width with no pair-kerning awareness.
  That trade-off (uniform tracking, no kerning pairs) matches how every
  mainstream vector tool's "letter spacing" control actually behaves
  (it's additive tracking, not a kerning-table override), so it's the
  right v1 target, not a shortfall — but worth stating explicitly since
  §6.2.6 originally deferred "per-character kerning controls" for
  exactly this complexity.
- **New fields**: `TextEntity.letter_spacing: float = 0.0` (extra
  em-relative or absolute-unit gap added between characters),
  `TextEntity.line_spacing: float = 1.0` (multiplier on the font's own
  default line height) — plumbed through `TextCreate`/`TextUpdate`/
  `TextDto` (`schemas.py`), `_entity_to_dict`/`_entity_from_dict`
  (`native_format.py:253`/`:376` — a native-format schema field addition,
  additive/backward-compatible the same way every prior entity-field
  addition in this codebase has been), the "Edit Text" dialog (two more
  numeric fields, same pattern as Size/Rotation), and
  `textFontOptions`-adjacent client DTOs.
- **`_text_profile`/`wire_for_profile` impact**: none expected beyond
  consuming more contours per Text entity — both already iterate "however
  many glyph contours `text_to_polygons`/`text_contour_wire` return,"
  with no assumption baked in that they come from a single `text_to_brep`
  call (confirmed by re-reading both — they walk `TopExp_Explorer` over
  whatever `TopAbs_FACE`s exist in the shape passed in). The recompose-
  into-one-Compound step above is what needs to preserve that property.
- **Files**: `backend/app/sketch/text_geometry.py` (the real work — line/
  character-level `text_to_brep` calls + font-metrics sourcing +
  recomposition), `models.py` (`TextEntity` fields), `schemas.py`
  (`TextCreate`/`TextUpdate`/`TextDto`), `native_format.py` (dict
  round-trip), `sketch_ribbon.dart` (two new dialog fields),
  `sketch_controller.dart`/`sketch_api_client.dart` (DTOs + PATCH call).
- **Risk**: medium-high, concretely bounded rather than open-ended — the
  single biggest unknown (a usable font-metrics source for advance widths
  and line height, reachable through the same `OC.Core.Addons`-only
  surface §1 already confirmed for `text_to_brep`/`register_font`) is a
  direct on-device check, not a research project, but unlike §2.1-2.3 it
  is a genuine unknown rather than a known-working reuse of existing
  code. **Recommend this on-device check runs first**, before committing
  to field names/schema shape, exactly as §6.2.6 recommended for the
  original OCCT-availability check.

---

## 3. Explicit v1 non-goals (carried over / newly added)

- "Explode text to editable curves" (already deferred in §6.2.6, still
  deferred here — depends on Spline per that section's own note).
- Arbitrary uploaded/system fonts (§2.2 only ever adds more *named*
  entries to the same bundled-and-licensed allowlist model, never opens
  up user font upload).
- True kerning-pair-table awareness for letter spacing (§2.4 — additive
  tracking only, matching every mainstream vector tool's actual "letter
  spacing" behavior).
- Interactive 3D-embedded resize/select/drag for Text (§2.1/§2.3 — 2D
  canvas first, matching the precedent Arc/Ellipse/Spline already set of
  rendering shipping well before selection/hit-testing).
- Non-uniform (independent width/height) text scaling (§2.3 — one `size`
  scalar stays the persisted model).

## 4. Suggested delivery order

1. **§2.1** (3D-embedded rendering) — smallest, reuses existing cached
   geometry, is the literal "add Text to the 3D viewport" ask, and has no
   dependency on anything else here.
2. **§2.2** (font selection audit/expansion) — independent of the other
   three; can run in parallel with §2.1 once a product decision on "audit
   vs. expand" is made.
3. **§2.3** (resizing — 2D drag handle) — independent, low risk, same
   established pattern as other tools' size handles.
4. **§2.4** (letter/line spacing) — last, because it is the one item with
   a genuine unconfirmed technical unknown (font-metrics source) that
   should be checked on-device before schema/field decisions are locked
   in, and because it is the largest, most self-contained chunk of new
   backend geometry work.
