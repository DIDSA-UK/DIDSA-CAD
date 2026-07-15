# DIDSA-CAD Sketcher — Architecture, Design Rationale, and UX Rethink Scoping

**Purpose of this document.** This is a standalone reference, separate from `docs/status.md` (chronological build log) and `docs/sketcher-overhaul-scope.md` (phase-by-phase implementation scoping for work already largely shipped). It exists to give a fresh LLM (or a human) everything needed to reason about a *structural* rethink of the sketcher's interaction model — not to re-litigate what's already been built, but to lay out exactly how the current system works, why it was built that way, where it demonstrably struggles, and what the live options are. Written 2026-07-15, reflects the codebase as of that date on branch `claude/sketcher-roadmap-tuning-7z3shf`.

The user's own framing, verbatim, for why this document exists: *"I'm still unhappy with the UX particularly with how entities and shapes resolve when moving things around. There may need to be a rethink on how the whole system operates as sketcher UX is too important and needs to be fast and intuitive."* Three specific ideas were raised to evaluate: (1) moving sketch solving onto the client with a push to the backend only on exit, to cut round-trip delay; (2) changing how translations work when moving entities or editing dimensions; (3) making sure shapes are created with the correct relationships in the first place. All three are addressed in §15, after the groundwork sections that follow.

---

## 1. High-level architecture

DIDSA-CAD is a Flutter client (`client/`) talking to a stateless FastAPI backend (`backend/`) that does all real geometry — 2D constraint solving via `py-slvs` (a SolveSpace fork) and 3D solid modeling via `pythonocc-core` (OCCT). The backend holds **no persistent database** — the client is the document's authoritative store between sessions (native-format save/load round-trips through the backend, per `docs/project-brief.md` §6/§8's original "API-first, stateless server, client holds the model" design). Within an active sketching session, however, the backend's `py-slvs` solve is unambiguously the source of truth for *solved point positions* — see §7 for the precise mechanics, since this distinction (document-persistence statelessness vs. per-operation solve authority) matters a great deal for §15's options.

Two halves relevant here:

- **`backend/app/sketch/`** — the 2D parametric sketch domain: `models.py` (entities), `constraints.py` (constraint types, each translating itself into py-slvs primitives), `solver.py` (the actual `solve_sketch` call), `profile.py` (closed-loop/profile detection feeding extrude).
- **`client/lib/sketch/`** — `sketch_controller.dart` (7,282 lines — all sketch mutation logic and client-held state), `sketch_canvas.dart` (3,642 lines — gesture dispatch and painting), `sketch_screen.dart` (hosts the canvas, wires in Part-editor integration), `dof_analysis.dart` (368 lines — a pure client-side, backend-independent topological DOF/rigidity preview).

---

## 2. Entity model (backend)

Every entity subclasses `SketchEntity` (`models.py:76-103`), carrying `id`, `construction: bool`, and a `type` discriminator. The single most load-bearing hook is `endpoint_point_ids()` (default `None`) — closed-loop/profile detection (§6) is built entirely on this: any entity returning a real `(start, end)` tuple automatically participates in chain-walking; anything returning `None` is handled as a standalone loop.

| Entity | Defining Points | Endpoint-connector? | Notes |
|---|---|---|---|
| **Point** | — | n/a | Plain `(id, x, y)`. Never auto-merged — two entities share a point only via deliberate shared id. Coincidence is a `CoincidentConstraint`, not identity. |
| **Line** | start, end | Yes | No auxiliary points/constraints of its own. |
| **Circle** | center, radius point, + 4 cardinal points (N/E/S/W) | No — always a standalone loop | 1 real (provisional) radius `DistanceConstraint`; 4 cardinal points each pinned via `EqualRadiusConstraint` + a zero-value axis `DistanceConstraint`, purely to give better snap targets than the arbitrarily-angled radius point. `delete_circle` cascades all 9 auto-created constraints. |
| **Arc** | center, start, end | Yes | 1 real (provisional) radius `DistanceConstraint` (center→start); end point tied to the *same* value via `EqualRadiusConstraint`, not a second independent distance — one editable radius, both ends stay circular under drag. Always sweeps CCW from start to end (fixed backend convention; the client tracks user intent and swaps start/end to fake CW — see §8.4). No native py-slvs arc entity used anywhere. |
| **Ellipse** | center, major/minor tip pairs (4 real rim points) | No | Each axis's positive tip has its own provisional `DistanceConstraint`; the negative tip is pinned as the reflection via `AtMidpointConstraint`. Two full-diameter `construction=True` Lines. A `PerpendicularConstraint` ties the axes together. No native py-slvs ellipse primitive exists — pure Point+Constraint composition. `major_radius >= minor_radius` enforced at creation. |
| **Polygon** | center + N vertices | No | First vertex's distance from center is the one real provisional `DistanceConstraint`; every other vertex ties to it via `EqualRadiusConstraint`. Consecutive edges get both `EqualLengthConstraint` *and* `AngleConstraint` (pinning the exterior angle to `360/sides`) — equal-length alone was found insufficient, converging to self-intersecting shapes under drag. A single `createPolygon` backend call builds the entire vertex/edge/constraint set atomically. |
| **Spline** | N through-points + `2*(N-1)` Bezier control points | Yes (first↔last through-point) | The **only** entity using a genuine py-slvs curve primitive (`SLVS_E_CUBIC`) rather than decomposition. `SplineTangentConstraint` enforces C1 continuity at interior joins. No closed/self-looping spline support. |
| **TextEntity** | 1 anchor point only | No | Deliberately **not** decomposed into geometry — glyph outlines regenerate fresh from `content`/`font`/`size`/`rotation_degrees` on every read, never persisted as points. Can yield multiple closed loops per entity (one per glyph contour, each with its own inner holes). |

### Slot is not a backend entity

There is no `Slot` class, no `add_slot`, nothing in `models.py`/`schemas.py`. It is entirely client-orchestrated from primitives in `SketchController._clickSlotTool` (`sketch_controller.dart:6278-6445`): a construction centerline (visual only, no constraint), two ordinary Arcs, two ordinary Lines, then — after the fact — the client deletes arc2's own two auto-created radius constraints and replaces them with 2 `EqualRadiusConstraint`s tying arc2's radius to arc1's, plus 4 `TangentConstraint`s (arc×line, all 4 pairs — the last 2 mathematically implied by the first 2 plus the equal-radius ties, an intentional redundancy the solver tolerates, see §4.5).

**This is architecturally significant for §15.3.** Unlike Polygon — which *is* a real backend entity with atomic creation, and which the client can specifically recognize for reinterpreting a vertex drag as a radius edit (`_polygonForVertex`) — Slot has **no server-side identity at all**. The backend sees "2 Arcs, 2 Lines, and a pile of constraints," nothing more. There is no equivalent drag-reinterpretation hook for Slot the way Polygon gets one; every Slot-specific behavior lives entirely in ad hoc client logic that has to independently recognize "these two arcs, these two lines, this constraint shape, is a Slot" every time it matters. This is also why a Slot placement costs ~20–25 round trips (§9) versus a Polygon's ~5+N — Polygon's atomicity was a deliberate later upgrade from an earlier multi-call client-orchestrated version; Slot never received the same treatment.

---

## 3. Constraint model (backend)

Every `Constraint` (`constraints.py:193-220`) implements `point_ids()` (dependency tracking) and `add_to_solver(builder)` (translates itself into py-slvs primitives — constraint classes never import `py_slvs` directly, keeping this module solver-agnostic).

| Type | Asserts | DOF removed | py-slvs primitive |
|---|---|---|---|
| `DistanceConstraint` | Fixed distance, `orientation` ∈ {linear, horizontal, vertical} | 1 | `addPointsDistance` / `addPointsProjectDistance` |
| `VerticalConstraint` / `HorizontalConstraint` | 2 points share X/Y | 1 | `addPointsVertical`/`Horizontal` |
| `AngleConstraint` | Fixed angle, 2 Lines | 1 | `addAngle` (+ supplement-ambiguity resolution, see below) |
| `CoincidentConstraint` | 2 points same position | 2 | `addPointsCoincident` |
| `ParallelConstraint` / `PerpendicularConstraint` | 2 Lines | 1 | `addParallel`/`addPerpendicular` |
| `EqualLengthConstraint` | 2 Lines same length | 1 | `addEqualLength` |
| `TangentConstraint` | Circle/Arc tangent to a Line | 1 | `addEqualLengthPointLineDistance` on a *virtual* centre-to-rim line — see below |
| `EqualRadiusConstraint` | 2 Circles/Arcs share radius | 1 | `addEqualLength` on 2 virtual centre-to-rim lines |
| `LineDistanceConstraint` | Perpendicular distance, 2 Lines | 1 | `addPointLineDistance` |
| `CollinearConstraint` | 2 Lines on one line | 2 | `addPointOnLine` ×2 (py-slvs has no single primitive) |
| `PointLineDistanceConstraint` | Perpendicular distance, point↔Line | 1 | `addPointLineDistance` |
| `AtMidpointConstraint` | Point pinned to a Line's midpoint | 2 | `addMidPoint` |
| `SplineTangentConstraint` | C1 continuity between segments | 1 (empirical) | `addCurvesTangent`, a specific boolean combination confirmed by direct experiment |

**The "virtual centre-to-rim line segment" trick.** Both `TangentConstraint` and `EqualRadiusConstraint` avoid py-slvs's native arc-of-circle entity entirely (found unreliable in the installed build). A `TangentConstraint` builds a line segment from center to the radius point (its length *is* the circle/arc's own real radius) and another for the target Line, then asserts `equal_length_point_line_distance` — the radius line's length equals the perpendicular distance from center to the tangent Line. Zero new solver entity types, but this composition is exactly what produces Slot's constraint redundancy (§4.5) and, as discovered this session, real solver fragility around unconfirmed (provisional) radii.

**Known sign/ambiguity workarounds** (worth knowing about, since they're exactly the kind of thing that makes "just move solving to the client" nontrivial — see §15.1): `addPointsProjectDistance` is genuinely signed, not magnitude, requiring the backend to pick the sign that preserves which side the point already sits on before solving; `addAngle`'s `supplement` flag is genuinely ambiguous between `degrees` and `180-degrees`, resolved by picking whichever is closer to the currently-measured angle; a zero-value H/V distance constraint (cardinal points) has a mirror-symmetric solution ambiguity fixed by a post-solve reflection check. None of this is exposed to the client at all — it's entirely internal to how the backend keeps py-slvs converging to the geometrically-intended branch rather than a mathematically-valid-but-visually-wrong mirror/flip.

---

## 4. The solver (`backend/app/sketch/solver.py`)

### 4.1 Batch, stateless, rebuilt every call

`solve_sketch` builds a **fresh `slvs.System()` from scratch on every call** — nothing persists between solves. The whole sketch (every point, every non-provisional constraint) is resubmitted and re-solved every time, whether triggered by a one-off dimension confirm or a throttled mid-drag tick. There is no incremental/local re-solve of just the changed region.

### 4.2 Groups and pinning

Two groups: `_FIXED_GROUP` (never touched by the solve) and `_SOLVE_GROUP` (everything else). The sketch's own origin point is permanently pinned into the fixed group on every solve (`update_point` explicitly rejects moving it). `anchor_point_ids` (see §4.3) is the *only* other way a point enters the fixed group, and only for one call.

### 4.3 `anchor_point_ids` — drag-solve semantics

Any point id passed in `anchor_point_ids` is pinned into the fixed group **for that one solve call only** (never persisted) — the dragged point holds exactly the position it already has going into the solve; everything else moves to accommodate it. If the anchored attempt fails to converge, `solve_sketch` retries once with the anchors dropped (external-body-reference points always stay pinned regardless, on both attempts) — documented reasoning: without the retry, a non-converged anchored attempt would still write back the (unmoved) anchored position, which *looks* like the drag worked until some unrelated later solve snaps it back — a confusing delayed correction.

### 4.4 Every point counted, not just constrained ones

`_solve_sketch_once` deliberately registers every point in the sketch (`for point_id in sketch.points: builder.point2d(point_id)`), not just ones a constraint happens to reference — this used to be skipped (hardcoded `dof=0` for an empty constraint set), which was wrong once `dof` acquired real UI meaning: a sketch with free, unconstrained geometry and zero constraints is the *opposite* of fully constrained.

### 4.5 `REDUNDANT_OKAY` special-casing — Slot's structural fragility

A Slot's closed loop (2 Arcs + 2 Lines tied by Tangent/EqualRadius) is mathematically over-determined by exactly one redundant equation. SolveSpace's own convention calls this `SLVS_RESULT_REDUNDANT_OKAY` (code 4); the installed fork reports 5 instead. The solver has a narrow, explicitly-scoped override that treats this as converged when `TangentConstraint`/`EqualRadiusConstraint` are present and every constraint type in the sketch is on an allowlist that deliberately **excludes `AtMidpointConstraint`** — because a real test proved the *same* result code can also mean a genuinely under-constrained shape (an HV-constrained rectangle whose position is never actually pinned) that py-slvs nonetheless reports `dof==0` for. A blanket override would have silently reintroduced that false positive.

**This session's finding, directly relevant to §15.3**: this override, while correct for *convergence*, left `system.Dof` itself untrustworthy for the specific case of a Slot whose radius is still unconfirmed (`provisional`, see §5) — py-slvs's naive param-count-minus-equation-count can't distinguish "the one genuinely-implied equation" from "every equation independent," so it reported `dof: 0` (fully constrained) the instant a Slot was drawn, before any dimension was ever signed. Fixed by flooring `dof` to `max(system.Dof, 1)` whenever a provisional constraint remains in the sketch and the solve converged — but this is a targeted patch over a structurally fragile constraint composition, not a fix to the fragility itself. **A genuinely redesigned Slot entity (real backend identity, not an ad hoc Tangent/EqualRadius web assembled after the fact) would not need this kind of workaround at all** — worth weighing directly in §15.3.

---

## 5. Provisional constraints — "hasn't been signed yet"

**Mechanism**: `DistanceConstraint.provisional: bool`. A freshly-drawn Circle/Arc/Ellipse/Polygon needs *some* constraint pinning its radius/size or it would collapse/wander under solve — but that auto-derived value is an artifact of wherever the user happened to drag, not a deliberate dimension. `solve_sketch` skips any `provisional=True` `DistanceConstraint` entirely (never added to py-slvs, contributes zero DOF-removal, "exactly as if it didn't exist"). The moment the user explicitly confirms a value (dimension-mode ghost confirm, or any direct PATCH with a numeric value), `provisional` is unconditionally cleared — a value write *is* the confirmation, there's no separate confirm flag/endpoint.

**Why this exists**: without it, every freshly-drawn shape would immediately read "fully constrained" (green padlock) with a dimension the user never actually specified — confirmed as a real on-device bug this project chased down earlier (`docs/status.md`'s "shapes report fully-constrained with zero user dimensions" investigation) and, per this session, still had one more manifestation (Slot's redundant system, §4.5) that had slipped through.

**Used by**: Circle's/Arc's/Ellipse's/Polygon's own single radius/axis constraint(s). Not used by Circle's cardinal-point zero-value axis pins (structural, not a size dimension).

This mechanism is the clearest existing precedent for "shapes should only look done once the user has actually said so" — directly relevant to whatever the rethink decides about §15.3's "correct relationships at creation time."

---

## 6. Profile detection and its role in extrude

`detect_profile` (`profile.py:85-215`) finds closed loops purely from `endpoint_point_ids()`-based connectivity (construction entities filtered out at the entry point, before any graph logic sees them), classifies each connected component as a usable loop only if every point in it has degree exactly 2 (a connected 2-regular graph is always a simple cycle), and folds in Circles/Ellipses/Text as standalone loops. Multiple loops get classified into outer profiles + nested holes by centroid-and-area containment, with a follow-up boundary-segment check (`_loop_fully_contains`) to catch loops that merely overlap or share an edge rather than being genuinely interior.

This result feeds `app.document.extrude.wire_for_profile` directly to build OCCT wires/faces. It's re-run, server-side, on **every single mutation in the sketcher** — it's folded into the universal "finish tail" every tool completion calls (§9), not something any individual tool opts into. This is one of many places where "every gesture pays for the whole sketch's structure being re-derived," a recurring theme relevant to §10 and §15.4.

---

## 7. Client architecture and state ownership

`SketchController`'s own class doc comment states the governing rule directly: *"The backend's solved point positions are always treated as the source of truth."* Concretely:

- **`_refreshAllPoints()`** (called after nearly every mutation, ~28 call sites) does `GET /points/{id}` **in a sequential loop, once per point id already known client-side** — not a single list call — then a `GET /profile`. This is the "pull authoritative state back down" step every tool completion, drag-drop, undo, and dimension confirm ends with.
- **Ordinary point drag**: every pointer-move issues a real `PATCH /points/{id}`, and the local point map is only updated **from the response**, never from the raw touch delta directly. There is no local prediction of the dragged point's own position ahead of the server echo.
- **The one deliberate exception**: dragging a Polygon vertex whose circumradius is already confirmed is reinterpreted as a dimension edit, and the controller does a **local-only speculative move** (compute the new radius, move the point locally, `notifyListeners()` immediately) *before* any network call, explicitly labeled in-code as "speculative local move for immediate 1:1 cursor tracking" — the throttled radius-update solve then pulls every vertex (including this one) onto the actual resized circle. This is the *only* place in the whole controller that predicts a solved position client-side.
- **`dof_analysis.dart`'s `SketchRigidity`** (fully documented in its own header) is a completely separate, purely topological (not numeric) client-side preview — union-find DOF-cost counting over the constraint graph, used only for green/red entity coloring, explicitly never a second source of truth. It answers "is this entity's *structure* fully determined," not "where are its points" — a genuinely different question the header comment is emphatic about, since a rigid-but-ungrounded cluster (everything fixed relative to everything else, but nothing tying it to the origin) is deliberately *not* colored green even though every point in it is locally rigid, matching how a user would actually judge "is this thing still draggable as a whole."

So today: **almost nothing about solved geometry is computed on the client.** The client's local state is a cache, refreshed by round trips after (almost) every action; the one place it predicts ahead of the server is a narrow, explicitly-labeled special case for one drag interaction on one entity type.

---

## 8. Tool-by-tool reference

Two conventions repeat in nearly every tool and are described once here:

- **The "finish tail"**: `_solveAndTrackDof()` (1 `POST /solve`) + `_refreshAllPoints()` (**N** individual `GET /points/{id}` calls, where N = total points currently known in the sketch, plus 1 `GET /profile`) + `_refreshConstraints()` (1 `GET /constraints`). Every tool completion, drag-drop, undo, and dimension confirm ends with this. **This tail's cost scales with total sketch size, not with what was just changed** — see §10.
- **`_pointIdAt(x, y, {excludeId})`**: the universal tap→point resolver almost every tool goes through. Reuses an existing point within snap radius (0 calls) → else snaps onto a nearby Line's midpoint via materialization (1–2 calls) → else creates a fresh point (1 call).

### 8.1 Line (click-to-click, H/V snapping)
Each tap after the first extends a chain: create one Line from the previous point to a new one, re-arm the chain. Tapping near the chain's own start closes the loop by reusing that id. Near-horizontal/vertical segments (within 4°) auto-fire a Horizontal/Vertical constraint. A closing edge never snaps (its slope is dictated by the loop). Cost per segment: ~4+N round trips, +1–2 for snapping/materialization.

A separate **midpoint-construction mode** exists: tap 1 is a pure client-side anchor (never sent to the backend), tap 2 places one real endpoint and computes+POSTs a second, mirror-image point — strictly two-tap, self-terminating.

### 8.2 Rectangle
Three construction methods (two-corner, centre-corner, three-point) share one builder. The axis-aligned methods add: 4 corner points, 4 Lines, 4 H/V constraints, **2 construction diagonal Lines**, 1 real center point (+ possible auto-coincident constraint), and **exactly one** `AtMidpointConstraint` on one diagonal only — a second on the other diagonal was found to make the solve numerically singular, a documented bug-fix. The 3-point (non-axis-aligned) method uses 3 `PerpendicularConstraint`s instead. Roughly **16–18+N round trips** — the most expensive "simple" shape tool per gesture.

### 8.3 Circle
Center tap, then a radius-only (never angle) second tap calling a special backend endpoint that materializes the radius point as the circle's own north cardinal point server-side. 4 cardinal points (N/E/S/W) always get created and individually fetched (`getPoint` ×4, since `_refreshAllPoints` only re-fetches ids already known locally). ~8+N round trips. An alternate 3-point construction method (2 anchor taps + 1 real tap, circumcenter computed client-side) exists too.

### 8.4 Arc (CW/CCW determination)
Center, start, end (projected onto the same circle, always toward wherever the cursor currently is). The client tracks a signed running sum of cursor-angle deltas since the start tap (handles multi-lap sweeps via wrapped angle deltas). At the final tap, if the net motion was clockwise, the client **swaps which rim point becomes `startPointId` vs `endPointId`** before calling the backend, since the backend's Arc entity always sweeps CCW by fixed convention and has no CW concept at all — this swap is a pure client-side interpretation layer.

### 8.5 Polygon
Center tap, first-vertex tap, self-terminating (like Circle). A single atomic `createPolygon` call builds every remaining vertex, every edge, and the whole solver constraint chain server-side — the *only* multi-entity shape tool this session's research confirmed is genuinely atomic on the backend (contrast Slot, §2). ~5+(sides−1)+N round trips.

### 8.6 Slot
The most expensive single-gesture tool in the file (~20–25+N round trips): 4 corner points, a construction centerline, 2 Arcs, 2 Lines, then a `GET /constraints` to find arc2's auto-created radius constraints, 2 deletes, 2 `EqualRadiusConstraint` creates, 4 `TangentConstraint` creates, then the finish tail. Every one of the ~9 creates + 2 deletes pushes its own undo closure — undoing one Slot placement replays ~11 inverse network calls. See §2's note on Slot's total lack of backend identity — this is the direct consequence of that architectural gap.

### 8.7 Ellipse
Center, major-axis-point (fixes radius+rotation), minor-radius-by-perpendicular-distance (silently clamped to never exceed the major radius). Backend returns 3 more points the client didn't tap (minor point, both negative tips) plus 2 construction axis Lines, each fetched individually. ~8+N round trips.

### 8.8 Spline
The one tool where nothing is created server-side until an explicit finish action. Each tap just resolves and appends a through-point id (1 API call, no solve). `finishSpline()` commits the whole accumulated list as one `createSpline` call; the backend auto-creates Bezier control-handle points and internal tangent constraints, each fetched individually. Per-tap cost is flat and cheap; all the expensive machinery happens once, at commit.

### 8.9 Text
Single self-terminating tap → anchor point → `createText` with fixed defaults (size 10, one allow-listed font, rotation 0) → finish tail → an *additional* `GET /texts/{id}/preview` fetching glyph contours (cached, not re-fetched per frame). All property edits go through a PATCH + another preview refresh. No dimension ghosts exist for Text at all — size/rotation are plain direct edits, not solver constraints.

### 8.10 Trim/Extend
Single tap per action, hit-tests only Lines (client-side scan, no API call for the hit test itself), the tapped line's nearer endpoint becomes the moved point. One `POST /lines/{id}/trim` finds the nearest real intersection and either moves that point in place or, if it was shared with other geometry, creates a **new** point and repoints the trimmed line to it, leaving the original untouched. Cheapest mutation tool per gesture (~5+N), but its shared-endpoint undo (no API exists to repoint a Line's endpoint id directly, so undo deletes-and-recreates instead) costs 3 extra calls.

### 8.11 Dimension mode
Entities are picked (≤2 at a time) via the same point-priority, midpoint-materializing resolver select mode uses. Ghost ("preview") ranges are computed **100% client-side from already-known point positions — zero API calls** to preview or live-update a ghost's value as the cursor or entities move. The ghost-combination table: 1 Line → length; 1 Circle/Arc → radius+diameter pair; 1 Ellipse → both axes' pairs; 2 Points → vertical+horizontal+linear triple; 1 Point+1 Line → substitutes the Line's nearer endpoint (an explicitly documented approximation — there's no real point-to-line distance constraint used here); 2 Lines → `lineDistance` if near-parallel (within ~1.1°), else `angle`.

**Confirming** a ghost is the provisional→real transition: an existing constraint of the matching orientation gets PATCHed, otherwise a new one is created; a *mismatched*-orientation existing constraint between the same points is deleted outright first (bug-fixed specifically because re-tapping a different-orientation ghost used to silently edit the wrong constraint). `setLineLength`/`updateSelectedConstraintValue` (the select-mode ribbon's direct-edit paths) are structurally identical, and both needed an explicit fix this session's predecessor work made: **PATCHing an already-existing constraint's value re-solves server-side, but used to leave the client's cached DOF state stale until some unrelated later mutation forced a fresh solve** — both now unconditionally re-run the finish tail even on the "just update an existing value" path.

### 8.12 Drag-mode — see §9, dedicated deep dive.

### 8.13 Auto-coincidence on drag
Point-to-point only proximity snap (no point-to-line drag-proximity snap exists — only the tap-placement midpoint-materialization path does that). A pure client-side linear scan finds the nearest existing point within a **fixed, non-zoom-scaled 0.5 sketch-unit radius**; if found, creates a `CoincidentConstraint` between the dropped point and it (two separate point ids, linked by constraint — not merged, so each stays independently draggable later) and shows a one-shot visual indicator. This is a *different* mechanism from the id-reuse snap ordinary tap-placement does (which returns the same id, welding references together at creation time with no new constraint at all).

### 8.14 Undo
Purely client-side, capped at 50 entries, never persisted or shared across sessions, no redo. Because the backend is the sole geometry authority, undo can't be a local-snapshot restore — every mutating method instead pushes a closure that performs the real inverse backend call(s). Create→delete is the common case; delete→recreate-with-a-fresh-id is used where deletion isn't reversible in place; the trim tool's shared-endpoint case and the Slot tool (~11 closures for one placement) are the most expensive inverses in the file. Cascade-aware deletion (`computeDeleteCascade`) captures every dependent entity before deleting, so one undo restores a whole cascade, not just the literal selection.

### 8.15 Selection / context actions
`SelectionKind` covers point/line/circle/constraint/arc/ellipse/spline/text. Selection accumulation, available-constraint-option lookup, and construction toggling are all pure client-side logic (free, no API calls) until an action is actually applied. `availableConstraintOptions` is a small, hardcoded table keyed on selection shape (1 Line → V/H; 2 Lines → Parallel/Perpendicular/EqualLength/Collinear; 2 Circles → Concentric/EqualRadius, *currently unwired, greyed out*; Circle+Line → Tangent, *also unwired*; any Point/Line mix → Coincident). Note: the 3D Part/Body editor's `contextActionsFor` (`viewport3d/selection_actions.dart`) is a **separate subsystem** — the sketcher's own equivalent is the ribbon (`sketch_ribbon.dart`), not that function.

---

## 9. The drag/move system — deep dive

This is the system most directly implicated in the user's stated UX complaint, so it's worth laying out completely rather than folding it into §8.

**Entering drag mode** is a sticky toggle, separate from ordinary tapping — while active, a tap grabs whichever point/line/label sits under the cursor, movement repositions it, a further tap drops it. (This replaced two earlier, explicitly worse designs: a 350ms double-tap timer, then an immediate-pointer-down grab — both are gone.)

**Grab resolution**: a direct point hit grabs itself; a direct line hit grabs as its own rigid body (both endpoints move together); a hit on a Circle/Arc/Ellipse/Spline/Text falls back to whichever of its defining points sits nearer the tap. The origin point is never offered.

**Beginning a drag is refused** if the point is in a structurally over-constrained cluster (checked both via the client's own topological `SketchRigidity` *and* the backend's last-reported failed-constraint ids) or is fully pinned — **except** a Polygon vertex whose radius is already confirmed, which bypasses those checks (it's not really "moving a point," it's editing a dimension). Beginning a drag makes **zero API calls** — it only records the cursor/point starting offsets, deliberately not PATCHing yet, since a grab tap typically lands a few pixels off the point's true position and PATCHing that raw offset would visibly teleport the point before any real drag motion happened.

**During the drag**, every single pointer-move event:
1. Computes the new position as `originPoint + (currentCursor − originCursor)` — delta-relative, never a direct snap to raw touch coordinates.
2. **PATCHes the backend immediately** (`PATCH /points/{id}`) and only updates the local/rendered position from the **response** — there is no local-only "ghost" position for the dragged point itself. Its on-screen position is always what the server last echoed back.
3. Fires a **throttled** (≤once per 120ms), **fire-and-forget**, **drop-not-queue** re-solve (`POST /solve` with the dragged point(s) anchored, then `GET /points` — a single list call, not per-point) so the *rest* of the sketch reflows around the dragged point during the drag, not just at the end. If a solve is already in flight when the throttle window opens, the new one is simply skipped rather than queued.

**Why the throttled mid-drag solve exists at all** (this is important context for §15.2): originally, a drag only moved the dragged point and re-solved once at drag-end. For a tightly-coupled constraint system (Polygon's equal-length/equal-radius/angle chain especially), one single large jump from "wherever it was" to "wherever it was dropped" gave Newton's method no reason to stay on the same continuous solution branch — it could converge to a different, mathematically-valid-but-visually-wrong root (a folded/self-intersecting polygon, a flipped dimension). This is documented, on-device-observed behavior, not a hypothetical. Solving periodically *during* the drag, each step reseeded from the last converged state, keeps Newton's iteration in the right neighborhood the whole way, rather than asking it to jump blind.

**On drop**: for an ordinary point, an undo closure capturing the origin position is pushed, the local auto-coincidence proximity check runs, then a final anchored solve + the full finish tail runs — the dropped point stays anchored for this last solve too, so the rest of the sketch settles around exactly where it landed. For a Polygon-vertex-radius drag, the drop instead PATCHes the radius constraint's value directly (with an undo that reverts the *value*, not a raw position).

**Line drag** rigidly translates both endpoints by the same delta each move (both PATCHed sequentially, both anchored in the throttled solve). **Special case**: dragging a Polygon's own edge redirects to a single-vertex drag on its start vertex instead — a straight-line rigid translation of a chord almost never keeps both endpoints on the shared equal-radius circle, so it would fight the Polygon's own constraint chain and visibly break the shape. This is explicitly framed in-code as "think of a Polygon edge/vertex drag as a scaling operation."

**Round-trip cost of one drag gesture**: 0 to begin, up to 1 PATCH per pointer-move event (2 for a line), roughly 1 solve+listPoints pair per 120ms of continuous movement, then on drop 1 auto-coincide check + 1 final anchored solve + the full N-point finish tail. A slow, deliberate drag can rack up dozens of round trips; a quick flick may only pay the drop-time cost.

**What this architecture gets right**: the anchor mechanism genuinely does deliver "I'm moving this one thing, the rest reacts around it" rather than an arbitrary whole-sketch re-settle, and the incremental mid-drag solving genuinely does prevent Newton's-method branch-jumping on tightly-coupled shapes (a real, previously-observed failure mode this design fixes). Both of those are correct, deliberate answers to real problems, not naive design.

**What it costs**: every frame of visible motion for anything *other* than the point directly under the finger depends on network latency arriving inside a 120ms window, repeatedly, for the duration of the drag. On a slow or lossy connection, "how entities and shapes resolve when moving things around" — the user's own words — is bounded by round-trip time, not local computation, because there genuinely is no local computation happening for the un-dragged geometry. The dragged point itself is *also* server-echoed, not locally rendered from the raw gesture, so even its own tracking depends on every PATCH round-tripping successfully and promptly.

---

## 10. Round-trip / latency inventory

Summary table (N = total point count currently in the sketch; this is the dominant scaling variable almost everywhere):

| Interaction | Approx. round trips | Dominant cost |
|---|---|---|
| Line, per segment | ~4 + N | finish tail |
| Rectangle | ~16–18 + N | diagonals/constraints/center point |
| Circle (center-radius) | ~8 + N | 4 cardinal-point GETs |
| Arc | ~5 + N | finish tail |
| Polygon (N-gon) | ~5 + (sides−1) + N | per-vertex GETs |
| **Slot** | **~20–25 + N** | tangent/equal-radius web (10 constraint calls alone) |
| Ellipse | ~8 + N | 3 extra-point GETs |
| Spline, per tap / at finish | 1 / ~4+M+N | control-point GETs at commit only |
| Text | ~6 + N | + 1 preview fetch |
| Trim/Extend | ~5 + N | cheapest mutation; shared-endpoint undo costs 3 more |
| Dimension confirm | ~2–3 + N | 1 constraint create/update |
| Drag, per throttled tick | ~2–3 every ≥120ms | PATCH + solve + listPoints |
| Drag, on drop | ~2 + N | anchored solve + auto-coincide |
| Undo, simple | ~1 + N | inverse call + finish tail |
| Undo, Slot / cascade delete | ~11+ + N | many inverse closures |
| Reference-ghost pick, first time | 1 | bundled materialization |
| Reference-ghost pick, cached | 0 | pure local cache hit |

**The single most important scaling fact**: `_refreshAllPoints()` — called after almost every mutation in the entire file — fetches points **one at a time**, in a loop, for every point id already known client-side, rather than a single list call. Every mutation, no matter how small, pays a cost proportional to *total sketch size*, not to what was just changed. The one place in the whole codebase that already uses the cheaper "list everything at once" pattern is the throttled mid-drag solve refresh (`GET /points` as a single list call) — the same pattern applied to the finish tail generally would likely be a large, low-risk latency win on its own, independent of any larger architectural rethink. Worth flagging as a candidate "do this regardless of what else is decided."

---

## 11. Rendering and feedback

- **Green/red entity coloring** is driven by two *independent* signals combined at the canvas: `SketchController.isFullyConstrained` (real, backend-confirmed `dof<=0` *and* the client's topological check that some point is grounded back to the origin) for the whole-sketch padlock, and `dof_analysis.dart`'s purely-topological `SketchRigidity` for per-entity coloring even when the whole sketch isn't done. The latter is explicitly documented as advisory-only, a fast local preview, never a second source of truth — deliberately diverging from py-slvs's own `Dof` in one specific way (treating a rigid-but-ungrounded cluster as *not* fully constrained, since it can still be dragged/rotated as a whole, even though py-slvs's own rank-based count would call that 0 too).
- **Dimension ghosts** (previews of a not-yet-confirmed value while picking entities in dimension mode) are computed 100% client-side from cached point positions — no network cost to preview or live-update.
- **`closedProfileFills`** (the shaded, filled area inside a closed profile) is refreshed as a byproduct of the finish tail's own profile GET — every mutation implicitly re-runs profile detection server-side, whether or not the mutation touched the profile at all.
- **Reference-ghost ("trace over an existing Body's geometry") system**: a Part-editor integration, not intrinsic to the sketcher — projected mesh-edge segments, vertex, and edge pick targets are computed once by the hosting `PartScreen` and handed down as plain immutable props. Picking a ghost vertex/edge materializes it as a real Point/Line via one bundled backend call, cached client-side so re-picking the same one later costs nothing further.
- **The 3D "backdrop"/hybrid-environment history**: an earlier design synced a perspective 3D camera behind the flat 2D canvas so drawn geometry and existing body context appeared in one continuous scene. It was **removed outright** after on-device use confirmed it never worked correctly — `flutter_scene` (the 3D rendering layer) has no true orthographic camera, only perspective with a fixed FOV, so anything off the single depth-plane the 2D canvas's own pan/zoom was synced to showed real perspective foreshortening a flat orthographic canvas can never reproduce. The scoping document that originally proposed syncing the two cameras (`docs/sketcher-overhaul-scope.md` Phase 7.1) explicitly flagged this exact orthographic-vs-perspective risk as something to prototype before committing — the prototype effectively failed on-device, and the feature was pulled rather than patched further. **Orbit View is now the only place real Body geometry is shown while sketching** (a separate, deliberately-different-camera mode you toggle into, not a synced backdrop), and `closedProfileFills` (backend-resolved) plus the reference-ghost system (see above) are what carry "context from the rest of the model" into flat 2D sketch mode instead.

---

## 12. Design decisions log — the "why" behind the current shape

Collected here so the scoping session doesn't have to re-derive rationale that's already been through review:

1. **Backend-authoritative solved positions, no client-side solver.** Rejected explicitly during the original Phase 3 scoping (`docs/sketcher-overhaul-scope.md`): deferring position-solving to sketch-exit was considered and rejected — not because it's impossible, but because (a) it doesn't solve constraint-status coloring on its own (that's a separate topological question, independently solved by `dof_analysis.dart`), and (b) it actively conflicts with the drag-solve semantics work happening in the same package — a sketch would visually look "unsolved" throughout editing, then jump when the deferred solve finally ran. **This is the direct prior-art precedent for the "move sketch to client" idea in §15.1** — read that rejection's reasoning carefully, since the situation has changed in some ways (constraint-status coloring is now solved independently and wouldn't need re-solving) and not in others (the jump-on-defer concern is still real, arguably more so with today's much larger constraint vocabulary — Slot's redundant Tangent/EqualRadius web in particular would be far harder to keep numerically stable under a from-scratch client reimplementation than the original, simpler system this rejection was weighed against).
2. **Client-side DOF/rigidity is topological, not numeric, and deliberately diverges from py-slvs's own count for grounding.** A pebble-game-style union-find over constraint DOF-costs, chosen specifically because "is this fully constrained" is a *structural* question answerable without ever running the real solver — instant, zero-round-trip, and correctly renders a rigid-but-ungrounded shape as still-draggable even where py-slvs's own rank count would call it 0.
3. **Provisional constraints exist so a freshly-drawn shape never lies about being "done."** Directly reusable precedent for whatever "shapes should be created with correct relationships" ends up meaning in §15.3.
4. **The incremental (throttled) mid-drag solve exists to prevent Newton's-method branch-jumping**, a real, previously-observed on-device failure mode (tightly-coupled shapes breaking/flipping on a single large drag jump), not a preference.
5. **The anchor-point-pins-during-solve mechanism is what makes drag feel intentional** rather than an arbitrary whole-sketch re-settle — "the point I'm holding stays exactly where I put it, everything else reacts."
6. **Slot never got the atomic-backend-entity treatment Polygon did.** Confirmed structural gap, not a stylistic choice — directly costs both round-trip count (§10) and solver robustness (§4.5), and is the reason Slot alone needed a special-case dof-floor fix this session.
7. **The 3D-backdrop hybrid-sketching idea was tried and pulled**, specifically because `flutter_scene`'s perspective-only camera couldn't deliver the "one flat continuous scene" premise it was built on. Not a rejected idea to avoid re-raising, but a concrete data point on what *doesn't* work for tying 2D sketch and 3D body context together.
8. **The finish tail's per-point `GET` loop appears to be an organic accident, not a deliberate tradeoff** — no comment anywhere defends it, and the one place in the codebase that already does the cheaper thing (`listPoints` for the mid-drag refresh) shows the alternative was known and available. Distinguishing this from the deliberate tradeoffs above matters for §15.4: this one looks like a free win, not a design decision to relitigate.

---

## 13. Known UX pain points (as reported)

- **General**: "unhappy with the UX particularly with how entities and shapes resolve when moving things around" (user's own words, this session). Given §9's analysis, this is very plausibly a *latency* complaint as much as a *behavior* complaint — every bit of geometry other than the point under your finger only updates when a network round trip lands, at best every 120ms, and the dragged point's own position is itself server-echoed rather than locally rendered.
- **Slot specifically**: this session found and fixed a real bug where a freshly-drawn Slot reported "fully constrained" before its radius was ever confirmed (§4.5), traced to the same redundant-constraint architecture flagged as a structural gap in §2/§12.6. A second, superficially similar on-device report (an extruded Slot producing a visibly wrong/collapsed body) turned out on investigation to be a bug in the *reproduction script* used to chase it down, not the product — but the underlying fragility of Slot's ad hoc constraint composition (no real backend identity, a deliberately redundant equation set, `REDUNDANT_OKAY` special-casing) is exactly the kind of thing that *could* produce a real version of that bug under different circumstances, and is worth treating as a standing risk regardless of whether this particular report turns out to be one.
- **Polygon**: needed multiple rounds of fixes this project's history (edge-drag breaking the shape, stale over-constrained reporting until re-entering the sketch, a Horizontal-constrained edge not actually being horizontal despite reporting fully constrained) before reaching its current, still-not-entirely-bulletproof state — all traceable to the same underlying tension between "make dragging feel direct and responsive" and "keep a tightly-coupled multi-constraint shape numerically well-behaved under a live, incremental solve."
- **General theme across the fix history** (visible in `docs/status.md`'s many entries): a large fraction of on-device bug reports in this sketcher have been some variant of "the client's cached constraint/DOF state went stale relative to what the backend actually solved" (missing a `_solveAndTrackDof()` call after some particular edit path) or "a drag/edit gesture on a multi-constraint shape converged to a different, technically-valid-but-visually-wrong solution branch." Both are direct, structural consequences of the current split-brain architecture (client caches, backend computes, and every edit path has to remember to re-sync) rather than one-off implementation mistakes — worth naming explicitly as a pattern, since a rethink that doesn't address the *pattern* will likely keep reproducing individual instances of it under new tools/shapes going forward.

---

## 14. What's genuinely open vs. already decided

Already decided/shipped, not worth re-litigating unless the rethink specifically wants to: the overall backend-as-solver / client-as-cache split (§12.1, though the *degree* of client-side prediction within that split is exactly what §15.1 revisits); topological (not numeric) client-side DOF preview (§12.2); provisional constraints (§12.3); throttled incremental drag-solving in principle (§12.4, though its *parameters* — 120ms, anchor semantics — are fair game); the 3D-backdrop hybrid environment (§12.7, tried and pulled — Orbit View plus profile-fill plus reference-ghosts is the current answer to "context while sketching," and any revisit of that specific idea should account for why it failed last time, not assume it wasn't tried).

Genuinely open, and the actual subject of this document: everything in §15.

---

## 15. Options for the scoping session

### 15.1 Move sketch solving to the client, push to backend on exit

**The idea as stated**: reduce round-trip delay by doing sketch geometry resolution locally on the client during active editing, only syncing to the backend when the sketch is closed/exited.

**What this would have to reproduce, concretely** (from §3/§4): a genuine constraint solver — not just "move points around," but Newton-iteration-based simultaneous equation solving for horizontal/vertical/linear distance (with the signed-projection ambiguity from §3), angle (with the supplement ambiguity), tangency and equal-radius via the virtual-line-segment trick, collinearity, at-midpoint, parallel/perpendicular, and Spline's genuine cubic-Bezier tangent-continuity constraint — plus the DOF/convergence reporting the UI depends on, plus Slot's redundant-system special-casing (§4.5), plus every one of the "known workaround" branch-selection fixes in §3 that exist specifically to keep the solver on the geometrically-intended solution rather than a mathematically-valid mirror/flip. This is a substantial, genuinely hard piece of software to reimplement and keep correct — not a thin wrapper. `py-slvs` itself is a mature, external, real-world-hardened solver; a client-side reimplementation (in Dart, presumably) starts from zero on all of the above, including bugs already found and fixed server-side over this project's history.

**Directly relevant prior art** (§12.1): a version of this idea was already considered and rejected once, for reasons that partially still apply and partially don't:
- *Still applies*: solving only at sketch-exit means the sketch visually looks "unsolved" (constraints not actually satisfied) for the entire editing session, then jumps when the deferred solve finally runs — likely to feel *worse*, not better, for exactly the tightly-coupled shapes (Polygon, Slot) already documented as fragile under large single-step jumps (§9's "why the throttled mid-drag solve exists" explanation is a direct, concrete illustration of this exact failure mode with today's incremental-solve architecture — a naive client-only local move with no continuous re-solve would reintroduce it, likely worse, since there'd be no py-slvs at all keeping the local edits numerically consistent along the way).
- *Doesn't apply as strongly today*: at the time of that original rejection, DOF/constrained-status coloring was the only thing motivating "solve locally," and that's since been fully solved independently via the topological `dof_analysis.dart` approach (§12.2) with zero backend dependency — so *that specific* motivation for local solving no longer exists. If the real goal is purely "make drag feel instant," a client-side solver is one way to get there, but not the only one — see the alternatives below.
- *New consideration this document's research surfaced*: the backend solver has accumulated a fair amount of real, hard-won correctness logic (§3's sign/ambiguity fixes, §4.5's redundancy handling, the provisional-constraint mechanism) precisely because getting a constraint solver's branch-selection right under real user gestures is genuinely subtle. Moving to client-side solving means either (a) porting all of that faithfully — real, nontrivial work, with real risk of reintroducing already-fixed bugs — or (b) accepting a client solver that's *less* correct than today's backend one, in exchange for lower latency. That's a real tradeoff worth stating plainly to whoever scopes this, not glossed over.

**A middle path worth scoping explicitly, short of a full client solver**: keep the backend as sole solver, but change *what* triggers a round trip and *how much* work each one does, rather than eliminating round trips altogether:
- Fix the `_refreshAllPoints` N+1 pattern (§10, §12.8) — a genuinely free, low-risk win, unrelated to whether client-side solving happens at all.
- Extend the "one finished entity = one solve call" convention (already used by every shape tool, §8) more aggressively — e.g. defer the mid-drag *reflow* solve (not the dragged point's own tracking) more, or make its throttle adaptive to observed round-trip time rather than a fixed 120ms.
- Consider whether the dragged point's own 1:1 tracking genuinely needs to be server-echoed on every pointer-move (§9) — a local, unconstrained render of the raw delta *while dragging*, reconciled against the server's response only periodically or on drop, would remove the dragged point's own responsiveness from the latency budget entirely, without touching how the *rest* of the sketch reflows. This is a much smaller, more surgical change than a full client solver, and directly targets "how entities... resolve when moving things around" for the one entity actually under the user's finger.

### 15.2 Change how translations work when moving entities or altering dimensions

Worth teasing apart into at least three distinct sub-questions, since "translations" could mean any of them:

- **Does dragging one point/line genuinely need to trigger a full whole-sketch re-solve, or could/should it be scoped to just the locally-connected constraint subgraph?** Today `solve_sketch` always resolves the *entire* sketch (§4.1) — for a large, mostly-unrelated sketch, a drag in one corner pays the cost of re-solving everything, not just the affected region. `dof_analysis.dart`'s own union-find clustering (§11) already identifies connected constraint components for DOF-coloring purposes — the same clustering could plausibly identify "which points could this drag even possibly affect," informing a scoped/partial solve rather than a global one. This is a backend-architecture question, independent of §15.1's client-vs-server question.
- **Should the dragged point's own on-screen tracking be decoupled from the server round trip** (§15.1's middle path) — a smaller, more contained version of "change how translation works."
- **Should the anchor semantics themselves change?** Today exactly the dragged point(s) are pinned and everything else is free (§4.3/§9). An alternative worth naming: letting the user designate *additional* points as temporarily anchored during a drag (a "hold this corner still while I move that one" gesture), which the existing `anchor_point_ids` mechanism already technically supports as a list, not just a single id — this might be a smaller, additive UX improvement independent of the latency question entirely, addressing a different complaint (predictability of *which* geometry moves, not *how fast*).

### 15.3 Make sure shapes are created with the correct relationships

Two concrete, already-identified gaps to weigh directly:

- **Give Slot a real backend entity**, matching what Polygon already has: atomic server-side creation (one call instead of ~9), a genuine identity the backend and client can both recognize (enabling the same kind of drag-reinterpretation special-casing Polygon gets via `_polygonForVertex`, currently entirely absent for Slot), and — most importantly per §4.5 — a constraint composition designed from scratch to avoid the deliberate Tangent/EqualRadius redundancy that necessitated `REDUNDANT_OKAY` special-casing and, this session, an additional DOF-floor patch on top of that. This is the single most concrete, scoped, "correct relationships at creation time" item this document surfaced.
- **Audit whether every shape tool's constraint web is minimal-and-sufficient, or accumulates redundancy the way Slot's did.** Rectangle's single-diagonal `AtMidpointConstraint` workaround (§8.2 — a second one was found to make the solve numerically singular) is a second, smaller example of the same class of problem: a constraint set assembled by composing individually-reasonable pieces (4 sides, 2 diagonals, equal/parallel/perpendicular ties) that turned out to have a redundancy only discovered by hitting it in practice. A systematic pass — for each shape tool, deriving the *true* minimal DOF-removing constraint set by hand and comparing it against what's actually built — would likely surface more of these before they show up as on-device bugs, rather than after.
- Separately: the provisional-constraint mechanism (§5/§12.3) is already exactly "don't let a shape claim to be fully specified until the user actually specified it" — worth explicitly deciding whether that principle should extend further (e.g., should Rectangle's or Ellipse's *position*, not just size, stay provisional/unsigned until something anchors it, the same way radius already does?).

### 15.4 Round-trip reduction independent of the above

Regardless of what's decided on §15.1–15.3, these are lower-risk, likely-net-positive items on their own:
- Replace `_refreshAllPoints`'s per-point `GET` loop with a single `listPoints` call (§10/§12.8) — the pattern already exists elsewhere in the same file for exactly this purpose.
- Consider whether the finish tail's separate `solve` / `points` / `constraints` / `profile` round trips could be collapsed into one combined response for the common "just finished a mutation" case, rather than 4 sequential requests.
- Consider whether Slot's ~10-call constraint-assembly sequence (§8.6) could be server-side-atomic even *before* a full entity redesign (§15.3) — a single new endpoint that takes the same inputs `_clickSlotTool` gathers today and does the arc/line/constraint assembly in one backend call, without necessarily giving Slot a first-class model entity yet, as a smaller intermediate step.

---

## 16. Open questions to resolve in the scoping session

1. Is the complaint primarily about **speed** (round-trip latency), **predictability** (which geometry moves and how, when you drag something), or **correctness** (shapes ending up in a different state than expected after a solve) — or some mix? This document's evidence points at all three being real and somewhat entangled, but the right fix differs materially depending on which is actually dominant in practice.
2. If any client-side solving is pursued (§15.1), how much: just the dragged point's own tracking (small, surgical, low-risk), or a genuine parallel constraint solver (large, high-risk, duplicates real backend logic)? These are very different scopes and probably deserve being treated as entirely separate proposals, not one spectrum.
3. Is a scoped/partial re-solve (only the affected constraint subgraph, §15.2) worth pursuing before or instead of moving solving location at all — i.e., is the *place* solving happens the actual bottleneck, or is it that *the whole sketch* gets re-solved every time regardless of what changed?
4. Should Slot get a real backend entity (§15.3) as a standalone piece of work regardless of what else is decided, given it's already both the most expensive tool per gesture (§10) and the one that needed a special-case bugfix this session?
5. What's the right prioritization between "ship the low-risk round-trip wins now" (§15.4) versus "wait for the larger architectural decision so they're not done twice"?
