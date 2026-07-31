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

**Status: §2.1 (3D-embedded rendering), §2.2 (font selection - expanded to
20), and §2.3 (resizing/position handles) are implemented; §2.4 (letter/
line spacing) is Phase 2, not started.** See §4's own updated delivery-
order section for what shipped and what's still open.

This is *not* greenfield, though: Text already shipped
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

- **Implemented.** Landed close to the proposal below, with one
  simplification found once actually building it: outline-only rendering
  (matching Circle/Arc/Ellipse/Spline's own existing 3D treatment, none of
  which are filled either), not a filled/holed polygon - `textPolygons`
  ended up a single flat `List<List<vm.Vector3>>` (one entry per glyph
  contour's outer loop *or* one of its own holes, each independently
  closed), not a separate outer/holes-per-contour structure, since a hole
  drawn as its own outline loop needs no polygon-with-holes triangulation
  at all. `SketchGeometry3D` gained `textPolygons`/`textIds`, populated in
  `sketchGeometry3DFrom` from a new `texts`/`textContours` parameter pair
  - the caller resolves the actual contours (`sketch_screen.dart`'s
    `_textContoursFrom`, via `SketchController.textLiveContours` for the
  actively-edited Sketch; `part_screen.dart`'s `_refreshSketchGeometries`
  fetches `GET .../texts/{id}/preview` directly for read-only reference
  Sketches, which had the exact same Text gap and got fixed alongside).
  `restrictToEmbeddedTools`'s Text exclusion is gone (`sketch_speed_dial.dart`).
  Selection/hit-testing (the item originally scoped out below) also
  shipped, not deferred - see §2.3.
- **Proposed approach** (original, kept for context): give `SketchGeometry3D` a `textPolygons`/
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

- **Implemented**: expanded from 8 to 20 (`backend/app/sketch/text_fonts.py`),
  spanning Simple (Open Sans, Roboto, Lato, Fira Sans, Barlow, PT Sans),
  Technical (IBM Plex Serif/Mono, Space Mono, Rajdhani, Barlow Condensed,
  Aldrich, Michroma, Audiowide, Arvo, Zilla Slab), and Decorative (Bebas
  Neue, Bungee, Abril Fatface, Marcellus) registers. Every new font is a
  genuinely static single-weight file, fetched from `google/fonts` -
  several once-static families that would otherwise have fit these
  categories (Inter, Work Sans, Oswald, Cinzel, Playfair Display) are now
  variable-only upstream with no `static/` fallback, and were deliberately
  passed over rather than adding more variable-font surface than Roboto
  already exercises alone (see `text_fonts.py`'s own updated comment).
  Connected-script/handwriting faces were deliberately excluded from the
  decorative set for the same closed-profile risk reason flagged below.
  Client-side: every font (all 20, not just the 12 new ones) is now also a
  registered Flutter asset font (`pubspec.yaml`, `client/assets/fonts/`),
  needed for §2.3's font-picker preview (each name rendered in its own
  face) - previously these were OCCT-side only.
  **The caveat below is unchanged and still real** - this sandbox still
  has no `pythonocc-core`, so none of the 12 new fonts have been run
  through a real on-device `text_to_brep` check yet. They were chosen
  conservatively specifically to manage that risk, and
  `test_stage19_text.py::test_create_text_with_each_allowlisted_font_over_the_api`
  (parametrized over the full `FONT_ALLOWLIST`, already existing, needed
  no changes) will exercise every one of them for real the moment this
  runs in an environment that actually has OCCT - the repo's own CI does
  (`.github/workflows/backend-verify.yml` builds the real Docker image and
  runs the full `pytest` suite there) - so this is a real, automatic
  safety net, not just a promise.
- **Current state** (original, kept for context): 8 OFL-licensed fonts already bundled (§1), already
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

- **Implemented**, including the interactive gap flagged below, and
  position (a "center handle"), which this section only mentioned as an
  aside. Two handles, shown only while a Text is the current selection:
  a **corner handle** that uniformly scales `size`, pivoting around the
  bounding box's own center (kept fixed - independent of the position
  handle, per the task's own explicit ask) via `SketchController.
  beginTextResizeDrag`/`updateTextResizeDrag`/`endTextResizeDrag`; and a
  **center handle**, which turned out to need no new drag mechanism at
  all - it's the Text's own real anchor Point, just rendered/hit-tested at
  the bounding box's center (a more intuitive drag point than the
  anchor's literal baseline-origin position) instead of its own literal
  coordinates, dragged via the exact same generic `beginPointDrag` every
  other Point already uses. Both use the app's existing tap-to-grab/tap-
  to-drop drag-mode gesture (`SketchController.dragGrabTargetAt`'s
  established pattern - a new `textResizeHandleGrabTargetAt` sibling
  checks the corner handle first, since it sits outside the glyph fill
  `dragGrabTargetAt`'s own hit-test only ever checks), not a new
  interaction language.
  A resize drag never PATCHes per frame (a real font-outline recompute is
  too expensive to run every pointer-move) - `_resizeLiveScale` is a
  cheap client-side multiplier applied to the already-cached preview
  contours for live rendering (`SketchController.textLiveContours`),
  committed as one real `size` PATCH plus one anchor-Point move on drop.
  A transient construction-line bounding box + center lines + width/
  height dimension labels renders alongside the handles - paint-time
  chrome only (`sketch_canvas.dart` for the 2D canvas, new
  `SketchGeometry3D.textHandleLines`/`textHandleMarkers` fields for the
  3D-embedded view), never real Line/Point entities, preserving
  `TextEntity`'s own "never decomposed into Points/Lines" design.
  The height-in-mm toolbar field (§4/new `sketch_text_bar.dart`) and the
  corner handle both ultimately just PATCH the same `size` field, so they
  naturally "overwrite each other" with no separate reconciliation needed
  - confirmed the right call before implementing, not assumed.
- **On-device feedback follow-up** ("you rolled out the features to the
  2D sketcher, I need them in the 3D viewport sketcher too"): the handles/
  bounding box/`TextValueBar` above were already generic across both
  views from the start (one shared `SketchController`, one shared
  `handleCanvasTap` entry point per `_handleEmbeddedSketchTap`'s own doc
  comment) - the real gap was discoverability, not a 3D-specific bug.
  Placing a Text left nothing selected, so none of the above ever
  appeared without a separate manual select-then-ribbon-chip step -
  trivial to stumble into by habit on the 2D canvas (glyphs are right
  there, easy to tap), much easier to miss entirely via a 3D ray-cast tap
  against text you don't yet know is there. Fixed at the root instead of
  patching the 3D path specifically: `_clickTextTool` now exits to Select
  mode, adds the new Text to `selectionSet`, and calls `openTextBar`
  immediately after a successful placement (paired with a second,
  explicitly requested UX change - "after placing the locating point,
  user should be sent straight to the text edit tool" - which turned out
  to be the same fix). Since both views share the placement code path,
  this makes the bounding box/handles/toolbar appear immediately in
  either one, with no per-view branching needed. `exitToSelectMode` also
  now clears `textBarTextId`, so switching draw tools (or entering
  Dimension mode) while the bar is open can no longer leave it dangling,
  disconnected from the selection that opened it.
- **Current state** (original, kept for context): `size` already exists as a plain numeric field,
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
- ~~Interactive 3D-embedded resize/select/drag for Text~~ — **implemented
  after all** (§2.3): building the resize/position handles turned out to
  need real hit-testing in both views together, not a 2D-first sequencing
  the way Arc/Ellipse/Spline's own rendering-before-selection precedent
  suggested. General tap-to-select (not just the two handles) on Text
  inside the 3D-embedded view specifically was not separately re-verified
  beyond what already existed.
- Non-uniform (independent width/height) text scaling (§2.3 — one `size`
  scalar stays the persisted model).

## 4. Suggested delivery order

1. **§2.1** (3D-embedded rendering) — **Phase 1, implemented.** Smallest,
   reused existing cached geometry, is the literal "add Text to the 3D
   viewport" ask, had no dependency on anything else here.
2. **§2.2** (font selection audit/expansion) — **Phase 1, implemented.**
   Expanded from 8 to 20 fonts.
3. **§2.3** (resizing + position handles) — **Phase 1, implemented,**
   including the 2D canvas *and* the 3D-embedded viewport (both were
   originally going to be sequenced separately, with 3D deferred behind
   §2.1's own selection/hit-testing carve-out - building the handles
   turned out to need real hit-testing either way, so both shipped
   together instead), plus a new `sketch_text_bar.dart` (`TextValueBar`,
   built on the same shared `ResizableToolPanel` shell `PatternValueBar`
   uses, per the task's own "use the pattern tool bar as a reference"
   instruction) that replaces the old modal "Edit Text" `AlertDialog` -
   Content/Font (expand-to-preview-in-face/collapse)/Height-in-mm/Rotation
   fields, each applying immediately on submit, draggable/scrollable like
   every other tool's own bottom panel.
4. **§2.4** (letter/line spacing) — **Phase 2, not started**, exactly as
   originally sequenced last: it is the one item with a genuine
   unconfirmed technical unknown (font-metrics source) that should be
   checked on-device before schema/field decisions are locked in, and it
   is the largest, most self-contained chunk of new backend geometry
   work. Explicitly deferred to a second phase per the task's own
   instruction, not dropped.

**Files actually touched, Phase 1**: backend - `text_fonts.py` (12 new
allowlist entries), `backend/app/sketch/fonts/` (12 new `.ttf`/`OFL-*.txt`
pairs). Client - `sketch_geometry_3d.dart` (`textPolygons`/`textIds`/
`textHandleLines`/`textHandleMarkers`, `sketchGeometry3DFrom`'s `texts`/
`textContours`/`selectedTextId` params, `buildSketchGeometryNode`'s new
render branches), `sketch_speed_dial.dart` (dropped the Text exclusion),
`sketch_screen.dart`/`part_screen.dart` (`_textDtosFrom`/`_textContoursFrom`
helpers, `TextValueBar` mounted alongside `SketchRibbon`), `sketch_controller.dart`
(`textBounds`/`textCenterHandle`/`textResizeHandle`/`textLiveContours`/
`textResizeHandleGrabTargetAt`/`beginTextResizeDrag`/`updateTextResizeDrag`/
`endTextResizeDrag`/`openTextBar`/`closeTextBar`, `textFontOptions` widened
to 20), `sketch_canvas.dart` (bounding-box/handle overlay, drag-mode grab
dispatch), `sketch_ribbon.dart` (old modal dialog removed, "Edit Text" now
opens the bar), new `sketch_text_bar.dart`, `pubspec.yaml` + `client/assets/fonts/`
(all 20 fonts as Flutter asset fonts, not just backend-side).

## 5. Phase 1 on-device feedback round (found and fixed post-implementation)

Four real gaps found once Phase 1 was actually used in the 3D-embedded
viewport, none of them "the 2D canvas got the feature and 3D didn't" so
much as one genuine cross-view gap plus three narrower bugs:

- **Auto-select/auto-open after placement.** Placing a Text left nothing
  selected, so the bounding box/handles/toolbar (all gated on being the
  current selection) never appeared without a separate manual select
  step - far more discoverable via a flat 2D tap than a 3D ray-cast one,
  which read as "3D never got the feature at all." Fixed by having
  `SketchController._clickTextTool` exit to Select mode, select the new
  Text, and call `openTextBar` immediately - the actual, literal "send
  the user straight to the text edit tool after placing" ask, and it
  happens to fix the cross-view discoverability gap too, since both
  views funnel through this one shared method.
- **Text had no hit-testing in the 3D-embedded ray-picking pipeline at
  all.** A second, genuinely separate gap from the rendering fix in §2.1
  - `sketchGeometry3DFrom` drew Text's glyph outlines, but the *hover/
  tap-select* system (`SelectionEntityKind`/`SelectionFilterState` in
  `selection_hit_test.dart`/`selection_filter.dart`, real GPU ray-casting
  against rendered geometry - entirely different from the flat 2D
  canvas's screen-space `_entityAt`) had no `sketchText` kind, so a 3D
  cursor tap or hover never found it; box-select/"select all" worked
  because those go through `SketchController`'s own entity-map iteration
  instead. Added `SelectionEntityKind.sketchText`, `hitTestSketchTexts`,
  wired through every consuming switch (`selection_hit_test.dart`,
  `selection_filter.dart`, `sketch_screen.dart`'s both-direction
  `SelectionKind`/`SelectionEntityKind` mappings, `selection_list_drawer.dart`'s
  icon/label, `part_viewport.dart`'s two highlight-node builders).
- **"Can't move the sketch's origin point" error while resizing.**
  `endTextResizeDrag` always tried to recompute the anchor Point's
  position to keep the bounding box's own center fixed after a scale -
  when the anchor is literally the Sketch's origin Point (a common
  placement - often the natural first tap in an empty Sketch), the
  backend unconditionally rejects that PATCH. Fixed by skipping the
  recenter for that one case and pivoting the resize from the anchor
  itself instead (the same behavior OCCT's own `size` scaling already
  has natively) rather than refusing the resize outright.
- **Bounding box/handles usable for dimensioning.** The box and center
  lines were (and still are) pure paint-time chrome with no backing
  geometry - correct per §2.3's own design, since `TextEntity` is
  deliberately never decomposed into Points/Lines - but that meant they
  were never *reachable* as a dimension target either. Fixed via the
  established `_nearestConstructionSnapAt` mechanism already used for a
  Line's midpoint and a Slot's own Arc apex: the corner and center handle
  positions (not the box outline itself - matching the same granularity
  every other shape's own construction-snap targets already have) are
  now real snap targets, hover-indicated the same way a Line midpoint is
  and materializing into a genuine, dimension-usable reference Point on
  tap - reachable regardless of whether the Text is currently Select-mode
  selected, unlike the box's own *rendering*.
  **Regression this uncovered**: the bounding box's own center (12, 5)
  for the fixture's default text) is also the single most natural place
  to tap to select the *whole* Text - now correctly loses to the new
  snap target instead (mirrors the existing, deliberate "a Line's own
  midpoint wins over selecting the Line" precedent), so several
  pre-existing tests that tapped dead-center to select the whole Text
  had to move a few units off both handle positions - not a design flaw,
  the same tradeoff Line-midpoint snapping already made.
