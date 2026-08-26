# LOD Strategy — coordination status

Tracking doc for a general "level of detail" (LOD) capability: show a fast, simplified
placeholder for an expensive Part/Feature while the real, detailed geometry builds, with a
toggle between simplified/full detail, and correct handling of downstream operations (e.g. a
Boss/Cut applied while a parent Feature is still coarse).

Motivating case: a spiral `BevelPairFeature` build took 12+ minutes and timed out on a phone.
The algorithmic root cause (an expensive meshing-phase search) was already fixed on `main`
(PR #167 warm-start/tiered search, PR #170 preview-phase fix, PR #172 end-cap-flattening
robustness — see `docs/status.md`'s 2026-08-26 entries). LOD is a *general* follow-on
capability, not a re-litigation of that fix: even a correctly-fast bevel pair is still slower
than an instant placeholder.

This doc is the durable state for a multi-session coordination effort — a coordinator session
(no direct implementation) plans, dispatches implementation to fresh child sessions, and
tracks their branch/PR/state here rather than relying on its own conversation memory. Update
this doc as you go, not just at the end.

Coordinator branch: `claude/lod-strategy-coordination` (this branch carries only this tracking
doc and any design-doc content — no implementation).

---

## Status at a glance

| Item | State | Branch / PR | Notes |
|---|---|---|---|
| Phase 0 investigation | in progress | — | 3 in-process Explore/general-purpose agents + 1 remote OCCT-profiling child session dispatched 2026-08-26 |
| Design doc | not started | — | blocked on investigation |
| Plan approval | not requested yet | — | blocked on design doc |
| Implementation chunks | not decomposed | — | blocked on approval |

---

## Phase 0 — investigation (dispatched 2026-08-26)

Four parallel research tasks, none of which write implementation code:

1. **Gear preview architecture** (in-process general-purpose agent) — deep read of
   `/document/gear/preview` and every `_gear_preview_*` handler in
   `backend/app/document/router.py`, whether/how the preview math is duplicated from the real
   Feature-construction modules, how the client renders it, and an assessed opinion on whether
   this 2D schematic-preview pattern can generalize into a real coarse-3D LOD mechanism or
   whether LOD needs something structurally different.
2. **Backend Feature-cost & `body_cache.py` survey** (in-process general-purpose agent) —
   confirms (or refutes) "zero async infra anywhere in this backend"; explains precisely what
   `body_cache.py` does and does not solve (repeat-call incremental rebuild, NOT first-build
   cost); structural (non-timed) survey of which Feature-construction modules
   (`gear.py`, loft, pattern, `boolean.py`, `split.py`, `surface.py`, `bevel.py`,
   `bevel_pair.py`, `gear_chain.py`, `planetary_gear.py`, plain extrude) look expensive from
   code structure alone (loop counts over user-controlled parameters, BRepAlgoAPI/loft
   operation counts).
3. **Client viewport3d / mesh / Feature-tree state** (in-process general-purpose agent) — how
   a Body's mesh reaches the client today, whether the client's state model has any
   per-Feature granularity, what the existing "slow build" UX (`_BuildingGeometryOverlay`,
   `GearDesignScreen`'s build hint) actually represents state-wise, and what's missing to
   support a real three-state (coarse-only / full-detail / toggled-to-coarse) per-Feature UI.
4. **Real OCCT profiling of untested candidates** (remote child session, research-only, no
   commits) — bootstraps `backend/environment.yml`'s conda env and measures real wall-clock
   time for `LoftFeature`, `PatternFeature` (at increasing instance counts), and the
   Boolean-family (`boolean.py`/`split.py`/`surface.py`) at realistic parameters. Already-known
   numbers (herringbone `GearFeature` ~6.4s, spiral `BevelPairFeature` up to ~193s worst-case
   pre-fix) are not re-measured.

Findings will be appended below as each completes, then synthesized into a design section.

### Finding 1 — gear preview architecture (complete)

`/document/gear/preview` (`backend/app/document/router.py`, `_gear_preview_*` handlers) is
confirmed 2D-only, zero-OCCT (`gear_math.py`/`gear_chain_math.py`/`bevel_math.py` — no
`OCC.Core.*` import anywhere in those modules), built on a repo-wide documented convention
(`docs/gear-design/00-conventions.md:53-60`, "OCCT-free `*_math.py` vs. OCCT-dependent
construction module" split, per Feature type).

**Verdict: this pattern does not generalize to a real coarse-3D LOD placeholder.** Three
structural reasons:
1. **2D-only by construction** — every preview response is `list[tuple[float,float]]` outline
   points; no code path produces a 3D shape/mesh. `12-spiral-bevel-gear.md:433-443`'s own
   scope-down (spiral curvature is "inherently an azimuthal/out-of-plane property" the
   schematic structurally can't show — direct the user to the real 3D solid instead) already
   makes this exact point for a narrower case.
2. **Pre-commit-only by construction** — `GearDesignScreen` is popped/replaced by `PartScreen`
   the moment Create/Save succeeds (`gear_design_screen.dart:460`, `:508-510`); preview and
   real geometry are never simultaneously mounted. LOD needs the placeholder to occupy the
   *same viewport slot* as the eventual real geometry and be toggled after the real Body
   exists — the opposite lifecycle.
3. **Gear-math-specific precondition doesn't hold for other Feature types** — `loft.py`,
   `pattern.py`, `boolean.py`, `split.py`, `surface.py`, `sweep.py`, `revolve.py`, `extrude.py`
   all import `OCC.Core.*` directly with no OCCT-free math sibling; there is no closed-form
   analytic substitute for "what will a loft/boolean/pattern result look like" the way an
   involute tooth outline is closed-form. Real LOD for these needs an actual coarse
   `TopoDS_Shape` from a **lower-fidelity pass through real OCCT**, not a 2D stand-in.

**Carried forward as real prior art**: (a) the cheap-vs-expensive module-split *category* of
idea, applied on the 3D side instead of via 2D math duplication; (b) a concrete drift-bug
lesson — the 2026-08-25→2026-08-26 meshing-phase preview bug (PR #170) is first-party proof
that a duplicated "fast path that must visually track a slow path" silently drifts unless it
either calls into the real shared logic or is pinned against it by a test; (c) the
debounce-cheap-path/settle-expensive-path UX cadence (`08-entry-screen-and-preview.md:22-27`)
is a reasonable rhythm to reuse conceptually for "placeholder now, swap in real geometry once
built."

---

## Open questions / cross-cutting decisions

*(none recorded yet — populated once investigation lands)*

---

## Dispatched implementation sessions

*(none yet — populated after plan approval, per session: branch, PR link, scope, state,
verification status)*
