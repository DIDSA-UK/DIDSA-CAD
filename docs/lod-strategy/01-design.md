# LOD Strategy — proposed design (Phase 0 synthesis)

Status: **proposed, not yet approved**. See `00-status.md` for the running tracker. This doc
is the concrete design the coordinator session is asking the user to approve before any
implementation is dispatched.

## 1. What this is and isn't

A general mechanism, for a small, named set of genuinely expensive Feature types, to:
- compute and show a **fast, real (if coarse) 3D solid** in place of the expensive full-detail
  geometry while the full build runs,
- swap the full-detail result in automatically once it's ready,
- let the user pin the coarse view back on afterward if they want it (the explicit "toggle"
  the user asked for),
- do all of this **without any new server-side async/job-queue infrastructure**, and without
  ever letting a downstream Feature (a Boss/Cut on a coarse-shown Body) operate on anything
  other than the real geometry.

It is not a job-queue rollout, not a 2D-schematic extension of the gear-preview pattern
(Finding 1 ruled that out directly), and not a change to any Feature's own already-fixed
construction algorithm (PR #167/#170/#172 stand as-is).

## 2. The central design decision: no background/async infra needed

The investigation was asked to independently evaluate whether background/async execution is
required, rather than assume it. **Conclusion: no, not for v1.** Reasoning:

- The backend's synchronous request/response model doesn't need to change for the placeholder
  itself to work: a **coarse build is just a second, much cheaper, real OCCT construction** —
  a `BRepPrimAPI_MakeCylinder`/`MakeCone` sized off the Feature's own already-known dimensions
  (a gear's addendum diameter and face width; a bevel gear's pitch cone) instead of the full
  tooth/loft/fillet pipeline. This is exactly the user's own framing — "a truncated cone/disc
  for a gear" — taken literally as the actual coarse geometry, not a metaphor. It runs in
  milliseconds and needs no pool, no worker, no job id.
- The **existing per-Feature-type request timeouts already comfortably cover the current
  worst case**: `spiralBevelPairRequestTimeout` is 720s against a measured worst case of
  ~170s (2026-08-26 entry); the blanket `documentRequestTimeout` is 90s. A client that fires
  (a) an instant coarse-mesh request, shows it immediately, then (b) the existing real
  create/update request in its own existing timeout window, has already solved "12 minutes
  staring at a spinner" — the spinner is replaced by a real placeholder for the exact same
  wait, using two ordinary sequential HTTP calls, no new backend architecture.
- True async (a job id, polling/websocket, real cancellation, the ability to keep editing
  other Features while one builds) would only matter if the goal were **UI concurrency during
  the build** (start Feature B while Feature A is still building) — nothing in the motivating
  report or the user's own framing asked for that, and every Create/Update flow in this app
  already blocks the UI for the duration of the call today (`_runGuarded`/`_busy`). LOD's job
  is to make that existing wait show something real, not to remove the wait or make it
  backgroundable. If the user wants true concurrent building later, that's a separate,
  larger, explicitly-flagged follow-on — not bundled into this effort.

This directly answers the investigation's own framing: **a cheap-but-real synchronous coarse
solid is sufficient for the whole problem as scoped**; the "genuine long tail" (a still-slow
symmetric spiral bevel pair) is handled by the *same* mechanism, not by a separate async path
— it just means the full-detail second request takes longer while the coarse placeholder sits
there, exactly as intended.

## 3. Where a "simplified representation" comes from, per Feature type

New, small, cheap-construction functions living **inside each existing OCCT-dependent module**
(not a 2D math duplicate — Finding 1 showed that pattern doesn't generalize past gears). This
is "the cheap-vs-expensive module-split idea, carried forward on the 3D side" per Finding 1's
own explicit recommendation.

Scope, cross-checked against both the structural survey (Finding 2) and the real OCCT
profiling verdict ("LOD justified for gears/Patterns/Lofts only" — Boolean-family confirmed
not worth it, matching Finding 2's structural prediction that `split.py`/`surface.py` are
bounded-cost and `boolean.py` is bounded by existing Body count):

| Feature family | Coarse construction | Notes |
|---|---|---|
| `GearFeature` (helical/herringbone), `BevelGearFeature`, `GearChainFeature`/`PlanetaryGearFeature` members | one `BRepPrimAPI_MakeCylinder` sized from addendum diameter + face width | skips wire/loft/fillet entirely — cheapest possible stand-in, matches the user's own "disc" framing |
| `BevelGearFeature`/`BevelPairFeature` | one `BRepPrimAPI_MakeCone` sized from the pitch cone geometry | matches the user's own "truncated cone" framing exactly; skips the N-face sew/heal pipeline and (for pairs) the meshing-phase search entirely |
| `PatternFeature` (`merge=FUSE_INTO_ONE` or `tool_feature_id` set) | skip the fuse chain — render the N rigid-transformed instances unfused (still real solids, just not booleaned together) | without merge, Pattern is already cheap (rigid transforms only); the expensive part is exclusively the sequential-fuse chain, so dropping just that step is a real, correct coarse pass, not an approximation of shape |
| `LoftFeature` | `ThruSections` between the **first and last section only**, skipping intermediate sections | one cheap loft call instead of N-section fidelity |

Each coarse builder gets a real-OCCT regression test asserting the coarse result's bounding
box is a reasonable proxy for the full result's (not byte-identical — it's deliberately
low-fidelity) — this is the concrete, cheap mitigation for Finding 1's drift-bug lesson,
proportionate to the actual risk here (which is much lower than the 2D preview case, since a
coarse builder deliberately discards detail rather than trying to track it).

**Explicitly out of scope for coarse builders** (per the OCCT profiling verdict and Finding
2's structural read): `BooleanFeature`, `SplitFeature`, `SurfaceFeature`, plain
Extrude/Boss/Cut, `RackFeature` (already cheap). If real usage later proves one of these
wrong, extending the same mechanism to it is a small, isolated follow-up — not a redesign.

## 4. Where it's computed, served, and how downstream Features stay correct

**Coarse geometry is never persisted and never enters the Feature graph.** It is computed
on-demand, purely for rendering, and is never the input to any Boolean/Boss/Cut resolution.
Concretely:

- A new query capability on the existing mesh machinery: `GET /parts/{id}/mesh?tier=coarse`
  returns `BodyMeshResponse`s (reusing the existing per-Body response shape) for any Body
  whose producing Feature is coarse-eligible, tagged `source: "coarse"` — a natural extension
  of the existing `source: "placeholder"|"computed"` enum, not a new response shape.
- For a **brand-new Feature being created** (the "user just hit Create on an expensive gear"
  case): the client calls a coarse-preview variant with the pending (not-yet-persisted)
  Feature payload — the direct 3D analogue of today's 2D `/gear/preview`, but returning a real
  coarse solid instead of an outline — and renders it immediately, before/alongside firing the
  real (slow) create request. Because the real Feature doesn't exist server-side until that
  create call returns, and the client already disables further edits during `_runGuarded`,
  **there is no window in which a downstream Feature could be created against the coarse
  stand-in** — the existing create-flow's own blocking behavior already prevents it.
- For **re-opening a Part that already contains a persisted expensive Feature** (cold
  `body_cache`, e.g. after a restart or a fresh import): `GET /mesh` first serves `tier=coarse`
  for the affected Bodies (fast), the client immediately follows with the normal full `GET
  /mesh` in the background, and swaps meshes in when it lands. A downstream Boss/Cut on such a
  Part always resolves via the real `compute_part_bodies`/`resolve_X` path regardless of what
  the client is currently rendering — this is unchanged from today's behavior, so a downstream
  operation transparently pays the same real cost it always has (this is not new latency LOD
  introduces; it's latency LOD does not remove and isn't trying to remove).

**This is the direct, non-hand-waved answer to "how is a downstream Feature on a still-coarse
parent handled": it is never handled specially, because it can never happen.** Coarse geometry
is strictly a client-rendering artifact; every real computation — including every downstream
Feature — always operates on the real body, by construction. There is no "operates on the
coarse stand-in and gets silently re-run later" mode anywhere in this design; the investigation
explicitly asked not to hand-wave this if full detail turns out to always be required for
downstream correctness — it does, unconditionally, and this design keeps that requirement by
never letting coarse geometry masquerade as real geometry at any layer.

## 5. Client-side plumbing (per Finding 3 — mostly generalizing what already exists)

- Generalize `PartViewport`'s existing single-slot `previewOverlayBodyId`/`previewOverlayMesh`
  (`part_viewport.dart:546-566`) into a `Map<String, MeshDto>` of coarse substitutes — the
  render-swap logic in `_syncMeshNode` is already close to this shape.
- A new small per-Feature/per-Body state container in `PartScreen`, following the exact
  `_hiddenFeatureIds`/`_rollbackExcludedFeatureIds` (`Set<String>` client-only state,
  `part_screen.dart:581,613`) convention: which Bodies are currently showing coarse-while-
  full-detail-is-pending, and (separately) which Features the user has manually pinned to
  always show coarse.
- Feature-tree badge: add a field to `FeatureDto`/`FeatureResponse` (`has_pending_detail` or
  similar) and one more `Stack` child / subtitle branch in `_buildFeatureTile`, directly
  mirroring the existing `hasLostReference` badge (`feature_tree_panel.dart:704-737`) — no new
  state machinery needed for the badge itself.
- Toggle affordance: since both the "pending" and "manually pinned to coarse" states need a
  `Set<String>` and a mesh-swap map regardless, a persistent user-facing toggle (pin coarse
  even once full detail is cached) is a cheap add-on once this plumbing exists — proposed as
  in-scope for v1 given how little marginal work it is, not a separate future effort.
- `quality`/`ViewPreferences.meshQuality` (the existing global tessellation slider) stays
  untouched and orthogonal — LOD is "which geometry" (coarse primitive vs. full construction),
  the quality slider is "how finely tessellated," and the two compose independently.

## 6. A genuinely separate, complementary finding worth fixing regardless of LOD

Finding 2 surfaced that `body_cache` — the existing repeat-call incremental-rebuild cache — is
bypassed on **every** create/update call and on **every plain `GET /features` list fetch** for
Gear/Loft/BevelGear/BevelPair/GearChain Features, because every "fresh entry point" resolver
unconditionally self-excludes its own feature id, forcing the uncached full-rebuild branch of
`compute_part_bodies`. For `BevelPairFeature` specifically, this means **loading the feature
list re-runs the entire spiral-bevel-pair build** every time. This is a real, narrowly-scoped,
independent bug — not something LOD needs to fix to work (LOD's coarse-first approach helps
regardless), but fixing it multiplies LOD's benefit (fewer moments where the expensive path is
even hit) and is low-risk/high-value on its own. Recommend dispatching it as its own small,
independent implementation chunk, first or in parallel with the LOD work.

Also flagged, lower priority, bundle-able with the Pattern LOD work: `PatternFeature`'s
`count_1`/`count_2`/`count_angular` have no upper-bound validation anywhere — a real (if
currently theoretical) unbounded-cost request is possible today. Worth a small server-side cap
alongside the Pattern coarse-builder work, same session, since it's already deep in that code.

## 7. Product questions — resolved by design, not left open

- **"Retroactive or new-Parts-only?"** — doesn't arise: coarse geometry is computed on-demand
  from a Feature's own already-stored parameters, never persisted, so it applies uniformly to
  every Part, old or new, with no migration and no distinction to make.
- **"Does the toggle matter enough to build now?"** — yes, included in v1, because it's a small
  marginal addition once the pending-state plumbing exists (see §5) — not treated as a
  separate open question requiring a decision, since the cost of including it is low.

No other genuinely open, user-must-decide question was found during this investigation. If one
surfaces during implementation, it will be raised here explicitly rather than guessed past.

## 8. Proposed implementation chunks (pending approval)

1. **Fix the `body_cache` self-exclusion bypass** (§6) — backend only, narrow, independent.
2. **Coarse-mesh mechanism + gear-family coarse builders** — `gear.py`/`bevel.py`/
   `bevel_pair.py`/`gear_chain.py`/`planetary_gear.py` cylinder/cone builders, the new
   `tier=coarse` query capability on the mesh endpoint(s), the new 3D coarse-preview endpoint
   for not-yet-created Features, `source: "coarse"` schema addition. The largest chunk — this
   is where the endpoint/schema plumbing lives, so every other coarse builder depends on it
   landing first.
3. **`PatternFeature` coarse builder** (skip-fuse variant) + instance-count validation cap —
   depends on #2's endpoint plumbing.
4. **`LoftFeature` coarse builder** (2-section shortcut) — depends on #2.
5. **Client: generalize mesh-swap to a map, per-Feature pending/coarse state, Feature-tree
   badge, toggle affordance, wire up both the create-flow and Part-reopen flows** — depends on
   #2 (and benefits from #3/#4 existing, though can be built against #2's gear-family coverage
   first and extended).

Each ships to its own branch/PR per this project's established pattern; `docs/status.md` entry
conflicts across parallel branches are expected and will be resolved at merge time, same as the
three 2026-08-26 sessions.
