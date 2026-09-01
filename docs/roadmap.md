# DIDSA-CAD Roadmap — Open Work

This tracks outstanding, not-yet-resolved work only. For project history and
everything already shipped/fixed, see `docs/status.md`. For the original
project spec, see `docs/project-brief.md`.

---

## Gear design tool

Full scope in `docs/gear-design/` (`README.md` is the index - start
there; `00-conventions.md` holds shared decisions every workstream needs;
one file per workstream after that, split specifically so a future
implementation session only needs to read the one workstream file it's
building, not one large combined doc). A new "Gear Design" entry point
(alongside the existing "3D Part Design"/"2D Drawing" tiles on
`ToolChooserScreen`) for parametric external, internal, rack-and-pinion,
helical, herringbone, compound, planetary, and straight bevel gears, plus
a general Loft feature. **Backend/API essentially complete**: Workstreams
1-5, 10, 11 done (gear math core, `GearFeature`, `RackFeature`, helical/
herringbone + `LoftFeature`, `GearChainFeature`/`PlanetaryGearFeature`/
`GearGroup`, `BevelGearFeature`, `BevelPairFeature`), plus a scoped-down
v1 entry screen/preview (Workstream 8, external/internal/rack only). Only
Workstream 9 (client-local presets) remains in this doc set. Key
decisions: gears are procedural Features (parameters -> solid), never a
DXF-round-trip or constraint-solved Sketch entities (`Spline`'s real
`py-slvs` solver backing makes it unsuitable for hundreds of involute-
curve points per gear); multi-gear systems (`GearChainFeature`/
`PlanetaryGearFeature`/`BevelPairFeature`) are each one live, re-derivable
Feature, mirroring Pattern/Mirror's existing "one Feature, many realized
Bodies" pattern, not a one-shot generator. Compound-gear geometry and
straight bevel gears were both pulled into v1 scope deliberately (the two
highest-risk items in the whole project) rather than deferred, and both
are now live; spiral/Zerol bevel gear/pair are scoped
(`docs/gear-design/12-spiral-bevel-gear.md`/`13-spiral-bevel-pair.md`) and
the single-gear half is now real, shipped code too. Three spikes ran first
(2026-08-21, Spike A, then Spike B, then Spike C). Spike A: NO-GO on the
originally proposed construction being conjugate "by construction" the way
Tredgold is for straight bevel - a corrected construction exists and is
close, but leaves a real residual. Spike B root-caused the two breakdowns
Spike A left uncharacterized, and found **neither is the flank-fold/
surface-quality risk both docs originally worried about** -
`_flank_fold_warning` never fires in either case, at any angle tested. The
high-spiral-angle breakdown is a fixed meshing-phase-convention artifact
(the same `±π/2` positioning constant calibrated for straight bevel, now
proven - not just suspected - to drift into a wrong-tooth alignment past a
geometry-dependent spiral angle; directly fixable by a small phase
correction, confirmed by direct recovery) - **a pairing-only concern**. The
extreme-tooth-count-ratio breakdown turned out to be an unrelated,
pre-existing defect in the existing straight-bevel profile-shift/solid-
assembly pipeline, not caused by or specific to spiral bevel at all - a
straight-bevel pairing-system bug this session surfaced and has since
fixed. Spike C designed and validated the two concrete pieces Spike B left
open: (1) a real per-build coarse-grid-plus-golden-section-refine phase
search (pairing-only), reliably recovering a good alignment across both
tooth-count ratios/both hands/a beta range spanning smooth through
notch-adjacent (a 96% overlap reduction at the one genuinely bad case
found) - **GO**, with a real, flagged cost risk (up to several minutes per
pair) concentrated exactly near the notch, where it matters most; and (2)
the calibrated tangential margin proxy Spike A/B's own numbers seemed to
require - which broader tooth-count-ratio testing found **isn't actually
needed**: the residual both prior spikes measured turns out to be mostly a
pre-existing, non-spiral structural property of equal-tooth-count Tredgold
pairs (a single balanced profile-shift correction can't resolve both
mating directions when the two members are identical), not a genuine
spiral effect - once tested on a resolvable tooth-count ratio, real
measured overlap is exactly zero across the whole spiral-angle range
tested, and the existing radial mesh-margin system, unchanged, already
predicts it correctly.

**Real implementation then landed for the single-gear half**:
`BevelGearFeature.spiral_angle_degrees`/`spiral_hand`, built directly
against the three spikes' own findings above, not a re-derivation -
`app.document.bevel_math.bevel_tooth_flank_sections` (the N-section,
default-3, layered-per-radius-rotation construction Spike A's own §2
corrected, reduces bit-for-bit to the existing straight-bevel case at
`spiral_angle_degrees=0.0`), a real N-section OCCT construction path in
`app.document.bevel._assemble_gear_solid` (reusing every existing flank/
tip-land/root-land/end-cap/sewing/validation helper unchanged, `ruled=False`
+ `CheckCompatibility(False)` per `gear.py`'s own established large-twist
fix), and `BevelDesignScreen`'s "Spiral" toggle on the client. Spike C's
own meshing-phase search was deliberately **not** part of this - it's a
pairing-only concern with no counterpart for a standalone gear.

**Real `BevelPairFeature` spiral-variant implementation has since landed
too** (the workstream that needed Spike C's own phase search): `BevelPair
Feature.spiral_angle_degrees` (pair-level shared - both members physically
mesh at one spiral trace) and `BevelPairMemberSpec.spiral_hand` (per-member,
so a real hand-of-spiral mismatch is representable and warned about); a real
`app.document.bevel_pair._search_meshing_phase` implementing Spike C's own
coarse-grid-plus-golden-section design, gated by the negative/`None`-overlap
guard and a marginal-solid pre-check that same spike called for; the
existing radial mesh-margin system reused completely unchanged, confirming
Spike C's own "no new tangential margin proxy needed" conclusion against
the real, committed code, not just a scratch harness; a dedicated, raised
client request timeout (`ApiConfig.spiralBevelPairRequestTimeout`) sized
against Spike C's own real per-trial cost numbers; and `BevelDesignScreen`'s
Bevel Pair mode gaining a shared "Spiral" toggle plus a per-member "Hand of
spiral" picker. Hypoid bevel remains the one thing still fully unscoped.
DXF import/export was originally scoped here too but has since moved to its
own doc set (`docs/dxf-io/`) - see the entry below.

## AI Modelling

Full scope in `docs/ai-modelling/` (`README.md` is the index - start
there; `00-conventions.md` holds shared decisions every workstream needs;
one file per workstream after that, mirroring `docs/gear-design/`'s own
per-workstream split). A new "AI Modelling" entry point (alongside the
existing "3D Part Design"/"2D Drawing"/"Gear Design" tiles on
`ToolChooserScreen`) - a user describes a part in plain English, an LLM
asks clarifying questions to scope it, then a client-side translator turns
the resulting structured plan into a real Feature-tree part via this
app's own Sketch/Feature API. **Status: all eleven planned workstreams are built** (see `README.md`'s
own delivery-order table) - every step kind except `gear_request`
(detected and surfaced, not auto-executed - a real, deliberate gap, see
`04-translator-and-execution.md`'s "Real scope of `gear_request`
handling") goes from a plain-English request, or an attached hand-sketch/
drawing photo, to a real Feature-tree part. The `gear_request` full
hand-off remains, per that same table. First real on-device feedback
round (2026-09-01, `docs/status.md`) fixed three concrete bugs (attached-
photo EXIF orientation not baked into pixel data before display/vision
call; the system prompt never told the LLM each fixed plane's actual
local-to-world axis mapping, so a second Sketch on a different plane could
land mirrored/offset relative to a first one built on another plane -
including this app's own intentional XZ chirality flip, which a generic
CAD-convention guess gets backwards; the image-extraction prompt not
asking for edge-anchored, view-to-view-correlated positions - and added a
plain-text-units instruction after a provider emitted LaTeX into a chat
view that only renders plain text) - see that entry for the on-device
verification gap this session couldn't close (no Flutter toolchain
available).
Key decisions: client-direct (Flutter calls the chosen AI provider - local
or cloud - directly; no new backend AI-brokering endpoint), a structured
JSON plan + deterministic client-side translator rather than freeform
LLM tool-calling against the live API, one new backend addition only (a
stateless dry-run plan-validation endpoint reusing every existing Feature
type's own `resolve_X` functions, never persisting anything), and a
provider abstraction unifying local + OpenAI cloud on the OpenAI-
compatible chat-completions wire shape with a separate Anthropic adapter.
Composes only from Sketch's existing entity types and a subset of
existing Feature types (gear-shaped requests route to the Gear Design
screens instead of freeform generation); reverse-engineering a photo of a
real physical object (rather than a hand sketch/engineering drawing) stays
a non-goal.

**Fillet/Chamfer edge selection had a real gap - single-arbitrary-edge
targeting - closed 2026-09-01 (`docs/ai-modelling/12-provenance-edge-
selectors.md`, built).** `03-structured-plan-schema.md`'s original four
selectors (`top_face_edges`/`bottom_face_edges`/`vertical_edges`/
`all_edges_of_face_at_position: <cardinal direction>`) are geometric
heuristics with no way to express "just this one edge" or "just this one
corner" - real on-device testing hit this ceiling. Two new selectors,
`edge_from_sketch_point`/`edge_from_sketch_line`, now resolve a specific
single edge by sketch-entity lineage instead (OCCT shape-history via
`.Generated()`/`.Modified()`, the same idiom `app.document.gear`'s own
root-fillet code already used) - `edge_from_sketch_point` (a corner) works
uniformly on Extrude/Revolve/Sweep with no known failure case;
`edge_from_sketch_line` (a specific straight edge, near or far side) works
the same way except a full-360° Revolve's own radially-oriented edges,
which fail closed rather than guess. Real, disclosed remaining gaps: only
a single-profile Boss with no `target_body_ids` (a fuse/cut/MultiProfile
rebuilds topology in a way the cached indices wouldn't survive);
`sketch_rectangle`/`sketch_polygon`/`sketch_slot` shorthands have no
addressable internal Lines for `edge_from_sketch_line` to name (only their
corner points, which `edge_from_sketch_point` already covers fine); the
mixed Line/Arc/Spline wire path and curved Sweep paths are unconfirmed.
Still real, not-yet-scoped follow-on payoff: the identical mechanism could
unlock `PatternDirectionStep`/`PatternAxisStep`'s own already-documented
"same problem" gap, and a `face_from_sketch_entity` counterpart could
unlock `CreatePlaneStep`'s currently-excluded `OFFSET_FACE`/etc. plane
types - neither designed or built here.

## Analysis tools

- **Measure tool.** Not yet scoped in detail - needs its own design pass
  (what can be measured: distance, angle, radius, between which entity
  types, etc.).
- **Sectioning tool.** Not yet scoped in detail - needs its own design
  pass (single vs. multiple section planes, planar vs. offset/stepped
  sections, a live/interactive cutaway vs. a static section view, and
  whether it also supports measuring/dimensioning the cut face).
- **Centre of gravity (CofG)** calculation for parts/assemblies.
- **Basic static stress analysis.**

## MBD part-data compliance

- **Part data to support MBD (model-based definition) and comply with the
  project's STEP MBD policy.** Fields needed on a part: material, part
  number, description, supplier, supplier part number, mass (with a
  checkbox to override the calculated-from-volume value when the user
  wants to enter a known mass instead), volume (calculated), surface area
  (calculated), and pattern features/bodies (so patterned instances carry
  the same part data as their source).
- **Hole tool** covering common standards and sizes: screw clearance
  holes, tap drills, and common drill sizes - selectable from a standard
  table rather than typed in as a raw diameter.
- **Material database** so a part's material can be populated easily from
  a picklist, with dependent metrics cascading automatically from the
  chosen material: density, stress data, colour, texture, etc.

## Sketcher tuning package

Notes from an original scoping pass on sketcher UX (selection/drag
interaction, constraint feedback, 3D context while sketching, drawing
tools, overall feel) - engineering breakdown in
`docs/sketcher-overhaul-scope.md` Phases 1-6, narrative history in
`docs/status.md`. Essentially all of it has shipped, including the
package's last deferred item (Polygon vertex-drag reinterpreted as a
circumradius-dimension edit, the on-device-feedback fixes that
followed it, a further round removing the broken 3D backdrop, adding
New Sketch on Face, and reworking the sketch-start camera sequence,
and Phase 11's trim/extend tool - see `docs/status.md`'s 2026-07-14
entries) - with one real gap confirmed by a direct code audit:

- **Phase 5's reference-axis alignment was never built.** Picking a
  line/edge as an aligning feature to set a new sketch's Y-axis (the
  "when creating the sketch, a line or edge can optionally be selected
  as an aligning feature" ask) has no implementation anywhere - only
  the discrete flip/90°-rotate half of Phase 5 ever shipped. Not
  scoped in detail yet.
- **The structural UX rethink was decided and is mostly shipped** -
  `docs/sketcher-restructure-plan.md` (2026-07-16) adopted an in-process
  FFI SolveSpace solver (`client/lib/sketch/local_solver/`) over the
  client-side-reimplementation idea `docs/sketcher-architecture-ux-scoping.md`
  (2026-07-15) had considered and rejected. `updatePointDrag`'s mid-drag
  reflow already tries it before falling back to the network path;
  `updateLineDrag` got the same treatment in `docs/status.md`'s 2026-07-21
  session. **Open sub-item found along the way**: a Horizontal/Vertical
  Constraint between two simultaneously-anchored Points, combined with any
  other Constraint reaching from one of them to a free Point, can make the
  native solver silently move an "anchored" Point - worked around with a
  drift-detection fallback (see that entry), but not yet root-caused at the
  FFI/SLVS level. **Correction to an earlier version of this entry**: Phase 2
  (plane-embedded 3D sketching/Orbit View) is *not* still unstarted - direct
  verification found it already shipped and essentially complete (nearly
  every draw tool, Dimensions, Trim/Extend, and drag mode all already work
  embedded in the 3D viewport; only the Text tool is deliberately excluded) -
  see `docs/status.md`'s 2026-07-17 P1-P10+ entries, which an earlier
  research pass in this same session missed. Phase 3 (Slot's real backend
  entity) shipped in the 2026-07-22 session below - Phase 4 (scoped/partial
  re-solve) is still genuinely not started.
- **Drag/solve rebuilt on closed-form geometry for Polygon/Slot** (2026-07-22
  session, see `docs/status.md`) - the redundant-constraint-chain approach
  above (Phase 1's FFI solver) is no longer how these two shapes drag at
  all; a formula has exactly one answer, so it eliminates the wrong-root
  class of bug for them entirely rather than reactively guarding against
  it. Real follow-ups from that pass, not silently dropped:
  - **Bisection/sub-step retry** for the *general* solver path (arbitrary
    hand-built constraint combinations, and a Polygon/Slot's own remnants
    once trimmed) - when a direct local solve fails a guard, retry via
    halving sub-steps between the last known-good position and the target
    instead of falling straight through to the throttled network path.
  - **Port `solver.py`'s `_fix_circle_cardinal_point_signs`** (detect a
    discrete mirror-flip root, correct it with a direct reflection through
    the known-good axis instead of rejecting outright) to the client's
    local solver, where it's confirmed not yet present - and extend the
    same detect-then-reflect shape to the general path's own Arc chord-side
    branch-flip guard, so a caught flip self-heals instead of just
    stalling.
  - **Ghost-preview drag** (decouple live rendering from the authoritative
    solve - a cheap kinematic preview every frame, one real solve at drop)
    for the general path specifically. No longer needed for Polygon/Slot
    (the closed-form path already removes the "wrong root flashing
    mid-drag" risk for those), so this is now polish, not a live-bug fix.
  - **Slot's own delete-cascade-with-undo** (multi-select delete cleanly
    removing a whole intact Slot, not leaving a dangling backend entity if
    only its Lines/Arcs happened to be in the selection) - `Polygon` needed
    this exact same follow-up fix after its own entity first landed
    ("select all > delete doesn't work on polygons, says constraint not
    found" - see `docs/status.md`); Slot hasn't gotten the equivalent pass
    yet.
  - **A Slot's arc-apex construction Points (2026-07-22 follow-up, see
    `docs/status.md`) don't auto-update on drag/resize** - deliberately
    unconstrained (no existing solver primitive expresses "stays
    diametrically opposite this Arc's own chord"), so once materialized
    they go stale if the Slot is later dragged/resized, unlike the
    centreline midpoint (which stays live via a real `AtMidpointConstraint`).
    Acceptable for v1 (a reference point the user places when needed, not
    something dragged independently), but worth a real fix - most likely by
    teaching the closed-form drag rebuild's own `_closedFormSlotGeometry` to
    also re-sync any materialized apex Points it finds, the same way it
    already re-syncs a/b/c/d.
  - **Residual-based redundancy verification** (`_residual_verified_
    convergence`/`_residualVerifiedConvergence`, 2026-07-22) only covers
    Distance/EqualLength/EqualRadius/Angle/Tangent/LineDistanceConstraint -
    a closed allowlist, deliberately (falls through to ordinary failure
    reporting rather than guess for any other type present). If a future
    on-device report surfaces the same "doubly-redundant but consistent"
    symptom involving a Parallel/Perpendicular/Coincident/Collinear/
    PointLineDistance/SplineTangent Constraint, that's the function to
    extend, following the exact same per-type residual-formula pattern.
- **Sketch dimension rendering/hit-testing has two independent
  implementations** (`sketch_canvas.dart` for the flat 2D canvas,
  `sketch_constraint_overlay.dart` for the 3D-embedded sketcher) that can
  drift out of sync - confirmed happened once already (the 2026-07-21
  dimension-overhaul session only fixed the 2D canvas; the 3D-embedded one,
  which is what `SketcherPreferences.defaultUse3DSketcher = true` actually
  shows by default, had the same bugs independently, plus one of its own -
  ported in the same day's follow-up session, see `docs/status.md`). Worth
  a future pass to unify the two into one shared implementation rather than
  two hand-kept-in-sync copies, if a third such divergence shows up.

## Text tool: 3D viewport, font selection, resizing, letter/line spacing

Full design pass in `docs/text-tool-3d-viewport-scope.md`. **Phase 1
shipped**: Text renders in the 3D-embedded ("Orbit View") sketcher and the
main Part viewport's reference-Sketch display (`sketchGeometry3DFrom`
gained real glyph-outline rendering - the actual gap
`SketchSpeedDial.restrictToEmbeddedTools` used to paper over by excluding
Text entirely, now removed); the font allowlist grew from 8 to 20
(Simple/Technical/Decorative registers, all still SIL OFL 1.1, all still
static single-weight files - deliberately excludes fonts that are now
variable-only upstream and connected-script/handwriting faces, both for
closed-profile risk reasons the scope doc's §2.2 explains); and Text
gained real corner (size, uniform-scale-about-center) and center
(position - its own existing anchor Point, just handled/rendered at the
bounding box's center) drag handles, in both the 2D canvas and the
3D-embedded viewport, via the app's existing tap-to-grab/tap-to-drop
drag-mode gesture, plus a transient construction-line bounding-box/
center-line/dimension overlay and a new pattern-bar-style `TextValueBar`
(replacing the old modal "Edit Text" dialog) with an expand-to-preview-
in-its-own-face font picker and a height-in-mm field that PATCHes the
same `size` the resize handle does. **Follow-up round**: all of the above
was already generic across the 2D canvas and 3D-embedded viewport, but
placing a Text left nothing selected, so none of it was ever reachable
without a manual select-then-ribbon-chip step - much easier to stumble
into on the 2D canvas than via a 3D ray-cast tap. Fixed at the root
(`_clickTextTool` now exits to Select mode, selects the new Text, and
opens `TextValueBar` immediately after placement - see scope doc §2.3's
own follow-up note), which also satisfies the separately-requested "send
the user straight to text edit after placing" behavior in one fix.

**Phase 2, not started**: letter spacing / line spacing. Genuinely new
backend work, and the one item with a real unconfirmed unknown - whether
`OCC.Core.Addons` exposes a font-metrics source (advance widths, line
height) for per-character/per-line layout, alongside `text_to_brep`/
`register_font`. Recommend checking this on-device before locking in
field names/schema shape, the same way the original Text-tool OCCT-
availability check was run before that work started. Multi-line content
entry (a prerequisite for line spacing to have anything to control) isn't
built yet either.

**Known follow-up, not yet done**: the 12 newly-added fonts have not been
run through a real on-device OCCT `text_to_brep` check (this project's
dev sandbox has never had `pythonocc-core` installed) - chosen
conservatively to manage that risk, and `test_stage19_text.py`'s existing
per-font parametrized test will exercise all 20 for real the next time
the full backend test suite runs somewhere `pythonocc-core` is actually
installed (this repo's own CI does, via the real Docker image).

## Standalone "2D Drawing" tool follow-ups

Thin v1 shipped 2026-07-21 (see `docs/status.md`): a bare, Part-free
`SketchScreen` reachable from a new `ToolChooserScreen` (between Connect and
the app's actual tools), with local file Save/Open via two new backend
endpoints (`GET`/`POST /sketch/sketches/{id}/export`, `.../import`, reusing
the Part-level native format's own `sketch_to_dict`/`sketch_from_dict`).
Deliberately deferred, not yet scoped in detail:

- **DXF import/export.** Now fully scoped (moved out of `docs/gear-design/`,
  which originally proposed it for a gear-round-trip workflow that's since
  been dropped - see `docs/dxf-io/README.md`). DXF-only, no DWG (no viable
  open-source writer/reader). Import lands as a positionable, constrainable
  "block" inside a Sketch (ghost geometry positioned by two real Points +
  a construction Line, not a plain numeric transform); export covers both
  a whole Sketch and any Body's own planar face, through one shared
  `ezdxf` writer. Not started - `docs/dxf-io/`'s own three workstream
  files are ready for implementation.
- **A "my drawings" list/browse feature.** No multi-document concept exists
  anywhere in the backend today (not even for Parts) - the current
  file-based Save/Open sidesteps needing one entirely. Would need either a
  real multi-document backend store or a client-side recent-files list at
  minimum.
- **Drafting fundamentals**: no units/scale, no layers, no sheets/paper
  size, no annotation beyond the existing Text entity - all absent, all
  real scope for a genuine floor-plan/drafting tool, not yet designed.

## Convert Entities / Offset Entities follow-ups

Both tools shipped (Convert Entities v1→v2, Offset Entities v1→v2 with
chain-aware corner-joining, curved-edge-to-Arc conversion - full history in
`docs/status.md`'s 2026-07-18 through 2026-07-21 entries). Known gaps left
deliberately unbuilt along the way, not yet scoped further:

- **A full circular Body edge (a real closed loop - both topological
  endpoints the same Body vertex) still 422s as `degenerate_edge`** before
  ever reaching curve-type detection, for both Convert Entities and Offset's
  body-edge picking. Real Circle extraction (as opposed to the now-shipped
  open-Arc case) is a separate, not-yet-built follow-up.
- **A converted circular edge's Arc centre Point is non-associative**
  (a plain `add_point`, not an external vertex reference) - unlike its
  start/end Points, it won't itself track a later change to the Body's
  shape. No existing mechanism pins a circular edge's own centre the way a
  vertex reference pins a corner; would need new backend design, not
  attempted.
- **Dragging a Convert-Entities-created (associative) Point visually works
  but snaps back on the next solve** - `dragTargetPointIdAt` has no
  exclusion for external-reference Points, the same inherited limitation
  every other pinned reference already has. Not fixed, not newly introduced.

## Reference drift / "potentially broken reference" health flag

User brainstorm (2026-07-31, prompted by the same day's three related bug
fixes - see `docs/status.md`'s "Bug fix: face-anchored Plane and Sketch
external references drifting..." and "Bug fix: Pattern/Mirror
`tool_feature_id` mode re-deriving an upstream Cut's tool shape..."
entries): those bugs were a *fixable* implementation defect (resolving a
`SubShapeRef` against the wrong point in the Part's own history), but the
underlying vulnerability they exposed is not fully closed by that fix - a
raw OCCT face/edge/vertex index (`topexp.MapShapes`'s own enumeration
order over one specific shape - see `SubShapeRef`'s own docstring) is
*never* a guaranteed-stable identity across a genuinely restructured Body
(a later fillet merging two faces, a cut consuming one entirely). This is
the industry-wide, still-not-fully-solved "Topological Naming Problem"
every history-based CAD kernel (Parasolid, ACIS, OCCT here) has some
version of - not unique brittleness in this project. Today, that
remaining case is handled by failing closed (a structured
`missing_reference` 422, or `has_lost_reference` for Sketch external
references) when resolution genuinely can't find a match at all. The gap:
nothing catches the case where resolution *succeeds* but against a
different face/edge than intended - exactly what happened here (a Plane's
`face_ref` silently landing on a side face instead of the top face it was
created against).

**The idea, not yet designed in detail**: alongside a `SubShapeRef` (or
`PatternDirectionRef`/`PatternAxisRef`/a Mirror's `mirror_plane`), store a
lightweight geometric signature captured when the reference was created
(or last confirmed healthy) - a face's centroid + normal, an edge's
midpoint + direction, a vertex's position. On every later resolution,
compare the newly-resolved shape's own signature against the stored one.
Small drift (the body legitimately grew/shrank a bit, the referenced
face moved slightly) is expected and fine; a normal that flipped
90°+, or a centroid that jumped to a different corner of the body
entirely, is exactly the "resolved successfully but wrong" failure this
session hit twice. Past some threshold, don't silently trust the new
value the way `refresh_external_references` currently does (it persists
whatever it resolves to, on every read) - flag the feature instead
("potentially broken reference"), the same way `has_lost_reference`
already flags a Sketch whose external reference can't resolve at all, but
generalized to every reference kind that can silently drift rather than
only the one that currently fails closed. Critically (the user's own
framing): don't auto-correct the feature's behavior based on the drifted
value - surface the flag and let the user decide, rather than the system
silently accepting a value that might be wrong.

The user's own rough starting language for thresholds - "normal changed by
more than ___", "sketch vertical changed by more than ___" - is a
reasonable first cut at the two most obviously-affected reference kinds
(a face-anchored Plane's own normal; a Sketch's in-plane orientation via
its anchor Plane's x/y axes) and is roughly the design direction to start
from, not yet worked out as real numbers/formulas.

**Precedent** (general industry concepts, not verified against any
specific vendor's documented internals - worth a real research pass before
or during implementation if matching prior art precisely matters, per the
user's own "align with NX or something" ask): the general "diff the
before/after state and require confirmation on a large change" pattern is
well-established outside CAD too (`terraform plan` refusing to silently
apply a change that would destroy more resources than expected; migration
tools that abort rather than silently touch an unexpectedly large row
count). Within CAD specifically, mature kernels/wrappers are understood to
mitigate the Topological Naming Problem partly via geometry-based
re-identification ("shape matching" / "sticky IDs") layered on top of raw
topological indices, rather than trusting a bare enumeration index alone -
OCCT itself exposes `BRepAlgoAPI_BooleanOperation::Modified()`/
`Generated()`/`IsDeleted()` for a boolean operation to report what became
of a given input face/edge directly, which this codebase does not
currently use anywhere (every resolver here re-derives identity purely by
re-enumerating a shape after the fact). A geometric-signature health check
is a heuristic safety net *on top of* the current approach, not a
replacement for wiring in that boolean-native tracking, which would be the
more thorough (and more involved) fix for the same underlying class of
problem.

**Open questions, not yet resolved:**
- Threshold values, and whether they should be absolute (a fixed angle/
  distance) or relative (e.g. a percentage of the Body's own bounding-box
  diagonal, so the same check behaves sensibly on a 10mm bracket and a
  10m assembly).
- Which reference kinds get this first - `CreatePlaneFeature.face_refs`
  and `PatternDirectionRef.edge_ref`/`PatternAxisRef` are the two directly
  implicated by this session's own bugs; `Sketch.external_references`
  already has a (weaker, resolve-or-fail-only) version of this via
  `has_lost_reference`, so may just need widening rather than a new
  mechanism; `tool_feature_id` itself is a Feature-id reference, not a
  raw topology index, so may not need a signature scheme at all.
- Whether a flagged feature still renders its best-effort (possibly wrong)
  resolved geometry, or freezes at its last known-good state until the
  flag is addressed.
- Whether/how a flag is dismissed once reviewed - does the user
  acknowledge "yes, this drift is intentional, stop flagging it" (updating
  the stored signature to the new value), or does it just clear itself
  once the signature re-stabilizes?
- Where the comparison logic would live - most likely a new sibling to
  `resolve_subshape_from_bodies` (`app.document.extrude`), called from the
  same handful of `_feature_response` branches `excluded_feature_ids_after`
  already touches, plus `pattern.py`/`mirror.py`'s own tool_feature_id
  resolvers.

Not scoped enough to estimate effort or start implementation - written up
here to capture the idea and the concrete bug reports that motivated it
before they're forgotten, per the user's own explicit "let's scope the
roadmap entry" ask.

## Other open items

- **A sketch's origin point reportedly doesn't line up with the correct 3D
  viewport origin.** User report (2026-07-21), investigated the same day -
  every basis-resolution path audited (backend `basis_for_sketch`, client
  `SketchPlaneBasis`, "New Sketch on Face") reads internally consistent, no
  bug found via static reading. The design question this was paired with
  has an answer: the origin is already a real, pinned backend Point, not a
  good candidate for the Convert-Entities-style external-reference
  mechanism (the world origin isn't a Body vertex to reference against).
  Needs an on-device repro to make further progress - does it happen on a
  fixed-plane Sketch, a custom-plane one, or specifically "New Sketch on
  Face"? Immediately on entry, or only after orbiting the camera?
- **Cast option for the main CAD viewport and the 3D mesh viewer.** User
  ask (2026-07-18): a proper in-app Cast button (matching YouTube/Netflix-
  style casting), not just Android's built-in screen-mirror toggle - lets
  a Chromecast/Cast-enabled TV show the 3D view directly. This needs
  Google's Cast Application Framework: a Custom Receiver (an HTML/JS page
  using the CAF Receiver SDK - effectively a second WebGL renderer for the
  mesh, since a live interactive 3D view can't just be a video stream)
  registered under a Google Cast SDK Developer Console account (one-time
  $5 fee), hosted at a public HTTPS URL, plus a sender-side integration in
  the Flutter app (no official Flutter plugin - would need a platform
  channel wrapping Android's native Cast SDK). Real scope, not a small
  addition. Not started - open questions before any implementation: does
  the user want to set up (or already have) a Google Cast developer
  account, and where would the receiver page be hosted (their own Pi, or
  a static host like GitHub Pages)? A sensible v1/v2 split once scoped:
  v1 a simpler static/turntable render or periodic snapshot pushed to the
  receiver, v2 a fully live orbit-synced remote render.
- **"Hidden lines" view mode.** Mentioned by the user as a wanted future
  addition. Not implemented. Would need its own render-mode entry
  (alongside Shaded / Shaded+Edges / Wireframe) that renders occluded
  edges distinctly (e.g. dashed) rather than hiding them entirely. (No
  longer tied to any occlusion bug - the C3 edge/face-highlight
  occlusion bug this was once floated as a workaround for turned out to
  have a real fix; see `docs/status.md`'s "C3 residual edge/face-highlight
  occlusion bug: resolved" entry.)
- **CI is green: 534/535 client tests passing, confirmed by real CI runs
  (not assumed).** All 26 pre-existing failures the new CI workflow first
  surfaced (see `docs/status.md`'s "CI now shows the real state of this
  test suite" entry and its many follow-up entries) are resolved - almost
  all were the test suite itself never having been updated to match
  already-shipped product changes, plus a handful of genuine small app bugs
  (`OrbitCamera._defaultDistance` contradicting its own doc comment's math;
  `dragTargetPointIdAt` able to return the sketch origin as a drag target;
  a `feature_context_menu.dart` bottom-sheet overflow) found and fixed along
  the way. Getting to green took nine CI round-trips, several of which
  caught mistakes in this session's *own* fixes (an unscoped `Listener`
  finder, a `find.byTooltip` position mismatch, a Hero-flight duplicate FAB)
  rather than declaring victory on the first apparent fix - see
  `docs/status.md`'s dated entries for the full history.
  - **One remaining failure, confirmed as CI-sandbox environment flakiness,
    not a code bug**: `part_viewport_test.dart`'s "Fix 4: tapping the
    viewport in selection mode over empty space" test intermittently hits
    this CI runner's lack of real Impeller/GPU support (`Flutter GPU
    requires the Impeller rendering backend, but Impeller is not enabled`)
    for that specific widget configuration - reproduced identically across
    multiple runs, with a sibling test in the same file only passing
    reliably because its own assertions happen to hold whether Scene setup
    succeeds or not. Not fixable from test-file changes; flagged rather
    than chased further.
  - Everything learned along the way about writing/fixing Flutter widget
    tests correctly (not just this project's specific bugs) is written up
    as a standalone reference in `docs/flutter-widget-test-lessons.md`.
- **Draco-compressed glTF/GLB support (`KHR_draco_mesh_compression`) - not
  implemented.** A real ODM/OpenDroneMap `.glb` export uses it; the mesh
  viewer currently detects it up front and fails with a clear, specific
  error rather than crashing (see `docs/status.md`'s "Same ODM file, real
  root cause found: Draco mesh compression" entry) - it does not actually
  decode the compressed geometry. Real Draco decoding needs an
  entropy/range decoder plus edgebreaker-style connectivity
  reconstruction - a genuine binary-codec implementation, not a small
  addition - and there's no ready-made pure-Dart package to lean on; a
  native/FFI Draco library would be a materially bigger dependency change
  (platform-specific binaries). Whether to pursue this, versus relying on
  re-exporting without mesh compression (available in most pipelines that
  use it, including ODM's), is an open question for the user - not decided.
- **glTF node transforms: full scene-graph walk now implemented, but
  `matrix`-based nodes are still rejected rather than decomposed.** The
  original fix only inspected root scene nodes, which turned out to be
  wrong for a real Blender export (the transform-bearing ancestor is often
  several levels above the actual mesh node) - now fixed via a full
  recursive walk composing every ancestor's transform (see
  `docs/status.md`'s "glTF node transforms, round 2" entry). The remaining
  gap: a node anywhere in the hierarchy using a raw `matrix` instead of
  separate translation/rotation/scale fields is rejected with a clear
  error rather than decomposed (correctly handling non-uniform
  scale/reflection when decomposing an arbitrary matrix is real
  complexity, not attempted here). Not decided whether it's worth building
  without a real file that needs it.
- **Larger Blender-exported `.glb` crash - root cause confirmed and fixed,
  not yet re-tested on-device.** A real `adb logcat` capture (see
  `docs/status.md`'s "The real, confirmed cause of the crash" entry) showed
  a genuine `java.lang.OutOfMemoryError` inside `file_picker`'s own
  `MethodChannel` encoding of the picked file's bytes (`withData: true`
  reads the whole file into a Java byte array and re-encodes it through a
  `StandardMessageCodec` envelope, needing roughly double the file's size on
  Android's small default Java heap) - not a texture or decode issue at
  all, and not a native/GPU fault either. Fixed by reading the file via its
  own path (`dart:io`) instead of requesting `PlatformFile.bytes`, so the
  platform channel never carries the file's actual content. Needs the user
  to confirm the same larger file now loads without crashing.
- **Mesh viewer Up-axis toggle only handles a Y/Z mismatch, not an
  arbitrary one.** Resolved for the real case that motivated it - a
  Blender export that skipped its "+Y Up" conversion, leaving the file's
  real "up" in Z instead of the glTF-spec-mandated Y (see `docs/status.md`'s
  "Root cause found: the file's own data isn't Y-up" entry) - via a new
  manual `MeshUpAxis` (`y`/`z`) View-menu toggle, since there's no reliable
  way to auto-detect this from the file alone. Not handled: a file with a
  totally different/arbitrary axis convention (e.g. X-up, or a non-90-degree
  misalignment) would need a more general fix than a simple Y/Z choice -
  not attempted, since no real file needing it has come up yet.
- **Mesh viewer decimation triangle-budget and default Up-axis settings are
  global, not per-device-profile.** `MeshViewerPreferences` (new this
  session) is a single flat set of values, not a saved list of profiles a
  user could switch between (e.g. "this phone" vs "that tablet") - fine for
  a single device, would need real design work to extend to multiple.
  Not requested, not attempted.
- **Silent re-save on Android.** On-device feedback: after PR #110's Save
  fix (`_canPersistFilePathForReuse` - see `part_screen.dart`), Android
  still prompts for a location/filename on every save, even a re-save of
  an already-saved Part - by design, not a bug: `file_picker`'s Android
  `saveFile()` only ever hands back a fabricated `Downloads`-guessed path,
  never a real, `dart:io`-writable one, so there is currently no way to
  silently reuse a prior save location there (desktop already does, since
  its path *is* real). Closing this gap for real would need a native
  Android Storage Access Framework integration - persisting a writable
  `ACTION_CREATE_DOCUMENT` URI's permission grant across app sessions (via
  `ContentResolver.takePersistableUriPermission`) and writing through that
  URI on subsequent saves via a platform channel - not something
  `file_picker`'s existing Flutter API exposes. Real scope (new platform
  channel/native Kotlin code, not a `file_picker` config tweak), not yet
  designed or attempted.
- **Investigate unifying sketch-level Pattern/Mirror's three duplicate
  translate/reflect implementations.** Phase 7 (`docs/pattern-mirror-scope.md`)
  and its on-device-feedback follow-up rounds (see `docs/status.md`'s
  2026-07-30 entries) ended up with the identical 2D pattern/mirror
  expansion math implemented three separate times: the backend
  (`Sketch.expand_pattern_and_mirror_instances`, `app/sketch/models.py`),
  the 2D sketch canvas's own client-side mirror
  (`pattern_mirror_expansion.dart`'s `expandPatternAndMirrorInstances`,
  consumed by `SketchController`), and - added for the embedded-3D (Orbit
  View) sketch editor's own hit-testing - a third,
  `hitTestSketchPatternMirrorInstances`/`_embeddedPatternMirrorGhostSegments`
  path in `selection_hit_test.dart`/`sketch_screen.dart`. Each was a
  deliberate, individually-justified instance of this codebase's existing
  "accepted duplication" convention for live-preview math (matching how
  `offsetPreviewGhosts` already duplicates real Offset logic client-side) -
  not an oversight, but three copies of the same translate/reflect/welding
  rules is more than that convention originally anticipated, and nothing
  enforces they stay in sync if the math changes again. Worth a dedicated
  investigation later (not attempted now): whether the two *client-side*
  copies (2D canvas + embedded-3D) could share one Dart implementation
  behind a thin per-consumer adapter, and whether that's worth the
  refactor risk against a working, well-tested feature - the backend copy
  almost certainly stays separate regardless (different language, and the
  one authoritative source of truth `detect_profile`/wire-building must
  use).
- **XYZ triad hidden behind any open tool panel - fixed (2026-07-31),
  not yet confirmed on a real device.** Every tool panel (`PatternPanel`,
  `ExtrudePanel`, `CreatePlanePanel`, `FilletPanel`, `ChamferPanel`,
  `SweepPanel`, etc.) is a `Stack` overlay sitting on top of the
  full-canvas `PartViewport`, while `triad.dart`'s `paintTriad` used to
  always draw the orientation triad at a fixed screen-space bottom-left
  offset inside that same canvas - so any open panel covered it
  completely, with no way to check orientation while actually using a
  tool. Fixed via a new `PartViewport.anchorTriadAtOrigin` flag
  (`PartScreen._anyToolPanelOpen`, ORing together every existing tool-panel/
  picker-ribbon active flag) that re-anchors the triad to the world
  origin's own projected screen position (`triad.dart`'s new, pure
  `triadCenterFor` helper, following the camera the same way
  `reference_planes.dart`'s real 3D-space geometry already does for free)
  while a panel is open, clamped to stay on-screen and falling back to the
  original fixed corner when the origin can't be projected at all (behind
  the camera) - falling back to the same fixed corner otherwise, unchanged
  from before this fix. Verified via `flutter test` (a new `triadCenterFor`
  unit-test group plus a `part_screen_test.dart` wiring test reproducing
  the bug's own absence/presence across two different tools - the New
  Sketch plane picker and `ExtrudePanel`, not just Pattern/Mirror) - **not**
  verified on an actual device with real GPU rendering and real panel
  layouts, since this sandbox has no display/GPU. Worth a real on-device
  glance before fully trusting the clamp-fallback behavior looks right at
  a variety of screen sizes/panel heights.
