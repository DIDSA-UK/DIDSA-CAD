# Pattern Component tool (Assembly lens) — bug investigation & fix plan

Status: **implemented** (see `docs/assembly-scope.md` §2y; B2 step 4 deliberately skipped).
Source: Flutter-client test report, 2026-11-03, with the frame assembly
`FRAME_ASSY_AI_TEST.didsa` + `LONG_RAIL_001` / `SHORT_RAIL_001` / `CORNER_POST_001` /
`GUSSET_001` part files.

Read `docs/assembly-scope.md` §2j (Phase 7), §2n (Phase 11), §2w (assembly-testing
pass) first for the history of this tool.

## Summary

| # | Report | Root cause | Where | Size |
|---|--------|------------|-------|------|
| B1 | Wrong rail position after confirming the pattern (preview right) | `_mat3_to_axis_angle`'s 180° branch picks signs relative to the X component; a rail rotated 180° about an axis with X≈0 comes out with a flipped axis on the **second** round trip | `backend/app/document/assembly.py` | S |
| B2 | Can't use edges/faces of patterned parts in mates | `resolve_occurrence_target` + `_check_mate_occurrence_path` do not understand `<src>#pattern:<pid>:<i>` path segments → 422 `occurrence_not_found` / `unresolved_mate_occurrence` | `assembly.py`, `router.py`, `assembly_solver.py`, `assembly_group.py` | M–L |
| B3 | Edges of patterned parts can't define a pattern direction | Same as B2 (`/component-patterns/direction-from-ref` → `compute_measurement` → `resolve_occurrence_target`) | — fixed by B2 step 1 | — |
| B4 | Instance naming convention unclear | Name = `name_override` → file basename → `Component N`; two unnamed instances of one part get **identical** names; pattern copies have **no** name (show as "Component"/"Body") | `client/lib/viewport3d/assembly_tree_panel.dart` | S |
| B5 | Error messages latch in the Assembly lens | `_errorMessage` is only cleared by `_runGuarded` (Part-lens ops); the banner has no dismiss; assembly tools never clear it | `part_screen.dart` | S |
| B6 | Can't pick pattern sources with the cursor | "+ Add source" only intercepts **tree** taps (`_onOccurrenceTap`); viewport component taps go to the normal select branch | `part_screen.dart` | S–M |
| B7 | Tool flow: direction first, then scope; pre-selection auto-added | Tool refuses to open without a selection; no step model; direction defaults to world X | `part_screen.dart`, `component_pattern_panel.dart` | M |

Recommended order: **B1 → B5 → B2(step 1, unblocks B3) → B7+B6 (one change) → B2(steps 2–4) → B4**.
B1 is a one-function fix with a reproducer in hand; B5 is trivial and improves every
later test pass.

---

## B1. Pattern copy placed wrongly after confirm (frame file)

### Reproduction (verified)

Pattern `1c85495d…` (Linear, +Z, count 2, 1150 mm) has 4 sources. Source *Short Rail
BOT_RIGHT* is stored with rotation axis `(-3.8e-13, 0.7071, -0.7071)`, angle `180.00000000004°`.

```
seed world                   axis=[ 0.    -0.7071  0.7071] ang=180  rot err=1e-08   (ok)
derived local (compose)      axis=[ 0.    -0.7071  0.7071] ang=180  rot err=1e-08   (ok)
derived world (mesh walk)    axis=[ 0.    -0.7071 -0.7071] ang=180  rot err=2.0     (WRONG)
```

The copy's local +Z (rail length) maps to world **+Y** instead of −Y, so the copy at
Z=1150 sticks out of the frame from Y=1200 to Y=2400.

### Root cause

`assembly._mat3_to_axis_angle`, `abs(theta - pi) < 1e-6` branch: takes
`|n_i| = sqrt((m_ii + 1)/2)` for all three components, then fixes the signs of **y and z
from `m[0][1]` / `m[0][2]`**, i.e. relative to X. When `n_x ≈ 0` those terms are pure
noise, so the y/z relative sign is random. The seed survives one round trip by luck
(its X noise had consistent signs); the derived instance is converted twice —
`expand_component_pattern_instances` → `compose(step, source)` and again in
`_walk` → `compose_chain([... derived])` — and the second pass loses the sign.

The client preview builds matrices directly (`step * sourceMatrix`) with no
axis-angle round trip, which is why the preview was right.

Any 180° rotation about an axis perpendicular to world X is affected (very common
for "flipped" parts) — this also hits plain nested sub-assemblies (`compose_chain`),
the GLB walk, export, measure and the mate solver, not just patterns.

### Fix

1. Replace `_mat3_to_axis_angle` with a robust conversion: matrix → quaternion via
   Shepperd's method (pivot on the largest of `trace, m00, m11, m22`), then
   `axis = v/|v|`, `angle = 2·atan2(|v|, w)`. `assembly_solver._axis_angle_from_quaternion`
   already does the second half — share it (move into `assembly.py`; the solver
   imports from there already). Minimal alternative: in the 180° branch pivot on the
   largest diagonal entry and derive the other signs from `m[i][j] + m[j][i]`.
2. Optional hardening: have `compose_chain` fold in matrix space and convert once at
   the end (fewer round trips, less drift).

### Tests

- `test_component_pattern_expand.py`: the BOT_RIGHT transform above, assert the
  mesh-walk world rotation matrix equals the source's (tolerance 1e-9).
- Property test in a new/existing assembly-math test: random axes incl. axes in the
  YZ/XZ/XY planes, angles 0, 180, 180±1e-10, 179.9999; `R(axis_angle(R)) == R`
  and idempotent over 3 round trips.
- Regression fixture: copy the attached frame (`FRAME_ASSY_AI_TEST.didsa` + the 4 part
  files) into `backend/tests/data/frame_ai_test/`; assert every pattern copy's world
  bbox **and** rotation matrix (bbox alone doesn't catch flips about the long axis).

---

## B2 / B3. Faces/edges of pattern copies unusable (Mate, pattern direction, Measure, Section)

### What happens today

- The client already hit-tests copies: `hitTestComponentInstanceEntities` returns
  face/edge/vertex refs whose `occurrenceId` is the instance path, e.g.
  `fb10…#pattern:1c85…:1`. (Only *whole-component* picks of copies are blocked:
  `part_screen.dart` `_toggleSelectedEntity` and `part_viewport.dart` box select.)
- The backend rejects that id everywhere:
  - `router._check_mate_occurrence_path` / `_validate_mate_entity_ref` → 422
    `occurrence_not_found` (Mate create/edit/preview).
  - `assembly.resolve_occurrence_target` (used by `assembly_solver`, `measure`,
    `section`, and so `/component-patterns/direction-from-ref`) splits on `/` and
    looks for an Occurrence literally named `src#pattern:…` → `KeyError` → 422.
- `occurrence_paths.py` already parses these segments (`parse_pattern_segment`,
  `resolve_path`) for Appearance/Scenes — reuse it, don't write a third parser.

### Fix — step 1 (unblocks B3, Measure, Section; required for mates)

Teach `resolve_occurrence_target` pattern-copy segments: for a segment with
`#pattern:`, look up the base occurrence, then the pattern on the *current* Part,
verify (not suppressed, occurrence ∈ sources, index ∈ `expand_component_pattern_instances(...)`)
and push the **derived** transform onto the chain instead of `occurrence.transform`.
Raise `KeyError` otherwise (callers already map it to their own 422). Note the
import-cycle: `occurrence_paths` imports `assembly`; put the parser in `assembly.py`
(or `appearance.py`, which has `PATTERN_SEGMENT`) and have `occurrence_paths` reuse it.

### Fix — step 2 (Mate creation)

- `_check_mate_occurrence_path`: accept a pattern-copy segment (same validity rules).
- Semantics (recommended v1): **a pattern copy is never driven by a solve** — it is
  rigidly derived from its source. Treat it like a fixed/grounded occurrence:
  - `assembly_group.discover_component`: add every top containing `#pattern:` to
    `frozen`. Verify the group model fetches a frozen side's pose through
    `_target_part_and_transform(ref.occurrence_id)` (it then gets the derived pose
    from step 1) rather than `by_id[...]`.
  - `router._mate_solve_target`: skip copy tops when picking the driven side; an
    explicit `occurrence_id=<copy>` → 422 with a clear message ("A pattern copy follows
    its source - mate the source, or move the other part").
  - Mate between a source and its own copy (or two copies of one source) → reject
    (they're one rigid body w.r.t. the solver) — extend the "different occurrences"
    check to compare `base source id`.
- Client: Mate panel labels (`mate_panel.dart:675`, `measurement_panel.dart:127`) look
  the copy up in `bodyNames` by full id → falls back to "Body". Use the B4 copy name.

### Fix — step 3 (lifecycle of mates that reference copies)

- `delete_component_pattern`: cascade-delete (or suppress + warn) mates whose
  references use the pattern — `occurrence_paths.path_uses_pattern` already exists.
- `update_component_pattern`: a count/skip change can remove index *i*; drop or
  flag mates that now reference a non-existent copy (same check as step 1).
- Occurrence delete (`router.py` ~3863 `mate_tops` filter) must also catch copies of
  the deleted source (`base_segment`).
- Native format round-trip needs no change (ids are strings), but add a test.

### Fix — step 4 (optional, later): copies follow when their source moves

With v1 a part mated to a copy won't follow when the *source* is re-solved/dragged
(the copy is frozen, not linked). Proper fix: in the group residual model, a copy's
pose = `step ∘ pose(source)` (constant world-frame left-multiply; for Circular with
`orient_with_rotation=false` keep the source rotation), and map copy → source for
graph membership. Defer unless testers hit it.

### Tests

Backend: Mate create + solve with one ref on a copy face (Coincident plane-plane,
Concentric edge); copy as the only movable side → 422; pattern delete cascades the
mate; `direction-from-ref` with a copy edge returns the rotated direction; Measure
between a copy and a seed. Client: mate panel shows the copy's name.

---

## B4. Instance naming convention

### Current behaviour (`occurrenceDisplayName`, `assembly_tree_panel.dart:26`)

1. `name_override` if set (e.g. "Short Rail BOT_LEFT");
2. else `external_ref` file basename ("LONG_RAIL_001"), unless it looks generated;
3. else `Component N` (N = position in the list).

Problems: two unnamed instances of the same file are indistinguishable (the frame's
unnamed long rail and any other un-overridden LONG_RAIL_001 would both read
"LONG_RAIL_001"); pattern copies have no name at all — selection drawer, Select Other,
breadcrumbs and Mate/Measure panels show "Component"/"Body"; nested paths (`a/b`)
also miss the `bodyNames` map. (`occurrences.take(index + 1).length` is just
`index + 1` — harmless.)

### Proposed convention (industry-standard `<name>:<n>`, as Fusion/Inventor; SolidWorks uses `<n>`)

- Placed occurrence without override: `<base>:<n>` where *n* is the 1-based ordinal
  among siblings with the **same `part_id`** in list order. Only append `:<n>` when
  that part is placed more than once? → **Recommend always appending** for parts
  placed >1 time, plain `<base>` when unique (less noise for the common case).
  User overrides are shown verbatim, never suffixed.
- Pattern copy: `<source display name> [<pattern display name> #<index+1>]`, e.g.
  `Short Rail BOT_RIGHT [Linear 1 #2]` — clearly derived, ties back to both the source
  and the tree's Patterns row.
- Nested path: last segment's name, with the parent in breadcrumbs as today.
- Implement as one helper `occurrencePathDisplayName(path, tree)` that every consumer
  (tree, `_selectionBodyNames`, Select Other, drawer, Mate/Measure panels) uses;
  populate `_selectionBodyNames` with entries for every instance path in
  `_assemblyMesh.instances`.
- Note: ordinals are display-time, so they renumber after a delete. If stable numbers
  are wanted, persist an `instance_number` on `Occurrence` (schema + native format
  change) — flag for product decision, not required for this fix.

Tests: `assembly_tree_panel_test.dart` cases for duplicates, overrides, copies.

---

## B5. Error messages latch in the Assembly lens

`_errorMessage` (red banner, `part_screen.dart` ~25702) is cleared only at the start of
`_runGuarded`, which Assembly-lens actions don't use. Fix:

1. Add a close (×) `IconButton` to the banner → `setState(() => _errorMessage = null)`.
2. Add `_clearTransientError()` and call it from every tool entry point: pattern
   (`_openComponentPattern`, `_openComponentPatternForEdit`), mate open, move/rotate,
   insert component, focus/exit focus, lens switch, and on a successful selection.
3. Guidance-type messages ("Select a component first…", "A derived pattern instance
   cannot be selected…") should not use the global error banner at all — show them
   in the active panel's own `error` line or a `SnackBar` that times out. With B7 the
   "Select a component first" message disappears entirely.

Tests: widget test — error set → open pattern tool → banner gone; × dismisses.

---

## B6 + B7. Pattern tool flow: direction first, then scope; viewport picking

### Target flow

1. **Open** (Add menu / ribbon / component context menu) — never refuses. If one or
   more components are selected (`_selectedOccurrenceId`, or the assembly multi-select
   set), they pre-populate the source list. Copies (`#pattern:`) and nested paths are
   filtered out with a short inline note.
2. **Step 1 — Direction** (active by default): edge-only selection filter pushed via
   `_selectionFilterOverrides` (like `_mateSelectionFilter`); prompt "Pick an edge for
   the direction". An edge on any instance — seed, nested, **or pattern copy** (needs
   B2 step 1) — resolves via `direction-from-ref` into Direction 1 (`custom`). X/Y/Z
   preset buttons stay as a fallback. Circular mode: same step picks the axis edge
   (and should also fill `axis.origin` from the edge — today origin is typed only;
   `direction-from-ref` could return a point on the line too).
3. **Step 2 — Components (scope)**: auto-advances after the direction is set (or the
   user taps the "Components" step). Component-only selection filter; a **viewport**
   tap on a component toggles it in/out of the source list (new branch in
   `_toggleSelectedEntity`'s component case, ahead of the `_selectedOccurrenceId`
   assignment, mirroring `_onOccurrenceTap`'s existing `_componentPatternPickingSources`
   branch). Tree taps keep working. Box select adds every hit top-level component.
   Tapping a copy → inline hint "pick the source component", not the global banner.
4. Count / spacing / 2nd direction / reverse as today; Confirm disabled until a
   direction and ≥1 source exist (show why).

### Implementation notes

- Replace `_componentPatternPickingSources` (bool) + `_componentPatternPickingDirectionSlot`
  (int) with one `ComponentPatternStep { direction, direction2, axis, sources }` (or keep
  the slot int and add `sources` as a slot) — one active pick target at a time; the
  panel renders a two-row stepper ("1 Direction · 2 Components") with the active row
  highlighted, each row clickable to re-enter it.
- Allow an empty source list while open (chip "delete" on the last chip becomes
  allowed); `_confirmComponentPattern` guards it. `_componentPatternPreviewInstances`
  already copes with no sources.
- Default `_componentPatternDirection` when opened fresh: unset/`custom` with no vector
  until an edge is picked, rather than silently world-X (or keep X but show it as
  "X (default)" — product call; recommend unset so the step is meaningful).
- Edit mode (`_openComponentPatternForEdit`) opens on the Components step with the
  stored direction shown.
- Keep the selection-override push/pop symmetrical in `_closeComponentPattern` and
  `_confirmComponentPattern` (and on lens switch / dispose).
- `_toggleSelectedEntity` already checks `_componentPatternPickingDirectionSlot` before
  the component branch — keep that ordering; add the sources branch right after it.
- Minor bug noticed: `_confirmDeleteComponentPattern` uses `part.id` instead of
  `focusPartId` (Phase 12 fixed this for create/update only) — fix alongside.

### Tests (`component_pattern_panel_test.dart`, `part_screen_test.dart`)

- Opening with nothing selected shows the panel on the Direction step (no error).
- Opening with a selected component pre-fills it as a source.
- Edge tap in Direction step sets a custom direction and advances to Components.
- Viewport component tap in Components step toggles the source list; copy tap shows
  the inline hint.
- Confirm disabled with no direction / no sources.

---

## Files touched (expected)

Backend: `app/document/assembly.py`, `app/document/occurrence_paths.py`,
`app/document/router.py` (mate path validation, `_mate_solve_target`, pattern
update/delete cascade, occurrence delete), `app/document/assembly_group.py`,
tests (`test_component_pattern_expand.py`, `test_component_pattern_router.py`, mate
solver tests, new frame fixture).

Client: `viewport3d/part_screen.dart`, `viewport3d/component_pattern_panel.dart`,
`viewport3d/assembly_tree_panel.dart`, `viewport3d/mate_panel.dart`,
`viewport3d/measurement_panel.dart`, `viewport3d/select_other_sheet.dart`,
`viewport3d/selection_list_drawer.dart`, tests.

Docs: add a §2y entry to `docs/assembly-scope.md` when implemented.

## Verification commands

```
/opt/sdks/micromamba run -n didsa-backend python -m pytest backend/tests/ -q
cd client && flutter analyze && flutter test
```
