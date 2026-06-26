# Stage 21 status — 2026-06-26

Branch: `claude/prompt-item-1-camera-gvbptx`.

## Items

| # | Item | Status | Notes |
|---|------|--------|-------|
| 1 | AppBar title layout fix | Complete | `part_screen.dart`, `sketch_screen.dart`, new `didsa_logo_button.dart` |
| 2 | Dark logo asset | Complete | `assets/images/didsa_logo_dark.png`; `connection_screen.dart` untouched |
| 3 | Midpoint constraint geometry fix | Complete (new backend constraint type) | `constraints.py`, `models.py`, `schemas.py`, `router.py`, `sketch_api_client.dart`, `sketch_controller.dart` |
| 4 | Select-all → delete still 400ing | Complete | `sketch_controller.dart` |

## What changed, by item

**1/2 — AppBar layout + dark logo**: Stage 20's AppBar `title` was a `Row`
with `MainAxisAlignment.spaceBetween`, which doesn't work as a `title` —
Flutter constrains `title` to a narrow centered slot between `leading` and
`actions`, so the `Row` collapsed to its children's intrinsic width
instead of spanning the bar. Fixed by moving the logo into `AppBar.leading`
(widened via `leadingWidth: 100`) and leaving `title` as right-aligned text
(`centerTitle: false`, `textAlign: TextAlign.right`), on both `PartScreen`
and `SketchScreen`.

Factored the logo into a new shared widget, `DidsaLogoButton`
(`client/lib/didsa_logo_button.dart`), since both screens needed the exact
same tap-to-website + `errorBuilder` fallback behavior:

```dart
class DidsaLogoButton extends StatelessWidget {
  const DidsaLogoButton({super.key});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: () => launchUrl(Uri.parse('https://www.didsa.uk'), mode: LaunchMode.externalApplication),
      child: Image.asset(
        'assets/images/didsa_logo_dark.png',
        height: 32,
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) =>
            const Text('DIDSA', style: TextStyle(fontWeight: FontWeight.bold)),
      ),
    );
  }
}
```

Uses the new dark logo variant (`didsa_logo_dark.png`, copied from the
user-supplied image, 1024×326 PNG) for contrast against the light AppBar
background — `ConnectionScreen`'s dark background still uses the original
light `didsa_logo.png` and was not touched, per the brief.

Added `url_launcher: ^6.3.1` to `pubspec.yaml`. `assets/images/` is
already registered as a whole directory, so no further pubspec change was
needed for the new PNG.

**3 — Midpoint constraint geometry**: The brief's literal instruction
("reuse the existing `line_distance` constraint type") doesn't actually
work — `LineDistanceConstraint` is hard-wired line-to-line (`line1_id`/
`line2_id`, anchored internally at Line 2's own start Point); there was no
existing constraint type taking an arbitrary Point id and a Line. Rather
than force a type-incompatible API call, added a new, properly generic
constraint type, `PointLineDistanceConstraint` (`type: "point_line_distance"`),
following the exact same dataclass/schema/router/DTO wiring pattern as
every other constraint type in the codebase. It reuses
`SolverBuilder.point_line_distance` (py-slvs's `addPointLineDistance` /
`SLVS_C_PT_LINE_DISTANCE`), which was already implemented generically in
`solver.py` but previously only ever invoked with a Line's own endpoint as
the point — never a true arbitrary Point id.

Files touched for the new type:
- `backend/app/sketch/constraints.py` — new `PointLineDistanceConstraint`
  dataclass (`point_id`, `line_id`, `distance`, plus captured
  `line_start_id`/`line_end_id`).
- `backend/app/sketch/models.py` — `Sketch.add_point_line_distance_constraint(point_id, line_id, distance)`.
- `backend/app/sketch/schemas.py` — `PointLineDistanceConstraintCreate`/
  `PointLineDistanceConstraintResponse`, added to both `ConstraintCreate`
  and `ConstraintResponse` unions.
- `backend/app/sketch/router.py` — dispatch branches in `create_constraint`
  and `_constraint_response`. No branch added to `update_constraint_value`
  — there's no user-editable numeric value for this type beyond its
  fixed 0.0 at creation, consistent with Vertical/Horizontal's 422 fallback.
- `client/lib/api/sketch_api_client.dart` — `PointLineDistanceConstraintDto`,
  wired into `ConstraintDto.fromJson`'s switch, plus
  `createPointLineDistanceConstraint(sketchId, pointId, lineId, distance)`.
- `client/lib/sketch/sketch_controller.dart` — `_materializeMidpoint`
  rewritten and `_recreateConstraint`'s dispatch given a matching case
  (needed for delete-undo's recreation path).

`_materializeMidpoint` now creates two constraints instead of the old
two-equal-`DistanceConstraint` pair:

```dart
// NOTE: mid-point: point-on-line (line_distance=0) + half-length distance to one endpoint
final halfLength = math.sqrt(math.pow(end.x - start.x, 2) + math.pow(end.y - start.y, 2)) / 2;
final onLine = await _api.createPointLineDistanceConstraint(_sketchId!, created.id, lineId, 0.0);
final toStart = await _api.createDistanceConstraint(_sketchId!, created.id, line.startPointId, halfLength);
_pushUndo(() async => _api.deleteConstraint(_sketchId!, onLine.id));
_pushUndo(() async => _api.deleteConstraint(_sketchId!, toStart.id));
```

This is the correct, solver-stable definition of a midpoint: pinning the
point onto the line's infinite extension (perpendicular distance 0) plus a
single half-length distance to one endpoint, rather than the old pair of
plain point-to-point distances (which only pinned distance from each
endpoint and let the point swing freely in an arc off the line — it never
constrained collinearity at all). Used `0.0` directly for the
perpendicular distance rather than the brief's suggested `0.001` fallback;
nothing in `solver.py`'s `addPointLineDistance` wrapper suggests py-slvs
rejects an exact-zero target, and this couldn't be verified either way in
this sandbox (no Python backend environment — see below), so this should
be the first thing checked on-device if midpoint placement fails to
converge.

Undo is pushed in the brief's specified order (constraint 2's undo first
in LIFO terms, so it pops before constraint 1's): `onLine`'s undo callback
is pushed first, `toStart`'s second, so undoing a midpoint placement
removes `toStart` before `onLine`.

Added pure-domain and API-level tests for the new type to
`backend/tests/test_stage15_constraints.py`, mirroring the file's existing
pattern for `LineDistanceConstraint`/`CollinearConstraint`:
`test_add_point_line_distance_constraint_between_a_point_and_a_line`,
`test_point_line_distance_constraint_pins_point_onto_line_after_solve`
(asserts an off-line point converges onto the line and to the correct
distance from its anchor endpoint), and
`test_create_point_line_distance_constraint_over_the_api`.

**4 — Select-all → delete still 400ing**: User-confirmed root cause from
live testing (superseding the brief's origin-point theory as primary):
`selectAll()` only ever populated `_selectionSet` with Points/Lines/Circles
— never Constraints. `deleteSelected()` already deletes in the correct
dependency order (constraints → lines/circles → points, fixed in Stage 20
item 2), but that ordering only ever covers constraints that were
*explicitly* selected. Any constraint left over on a selected Line (e.g. a
`VerticalConstraint`, which captures its Line's endpoint Point ids at
creation time and is never auto-deleted when that Line is deleted) still
blocks the subsequent Point delete with `"Point is still referenced by
constraint <id>"`.

Fixed by having `selectAll()` also select every Constraint in the sketch:

```dart
..addAll(constraints.keys.map((id) => SketchSelection(kind: SelectionKind.constraint, id: id)));
```

This is option (a) from the two choices the user laid out — selecting
literally everything on select-all, rather than (b) having
`deleteSelected()` itself infer which constraints transitively reference
any selected Point/Line. (b) would need every constraint type's underlying
Point ids exposed in its response DTO to compute reliably client-side —
today only `DistanceConstraintDto`/`VerticalConstraintDto`/
`HorizontalConstraintDto`/`CoincidentConstraintDto`/
`PointLineDistanceConstraintDto` carry Point ids on the wire; `Angle`/
`Parallel`/`Perpendicular`/`EqualLength`/`Collinear`/`LineDistance`
responses only carry Line ids. (a) sidesteps that gap entirely and matches
what "select all" should mean anyway.

Also added the brief's explicitly-requested defensive origin-point filter
to `deleteSelected()` itself (not just `selectAll()`, which already
excluded it before this stage) — silently dropped rather than left to
surface as a 400-driven `errorMessage`, since it's never a meaningful
delete target:

```dart
final toDelete = List<SketchSelection>.from(_selectionSet)
  ..removeWhere((s) => s.kind == SelectionKind.point && s.id == _originPointId);
if (toDelete.isEmpty) return;
```

## Test/analyze results

Same sandbox limitations as every prior stage, plus one newly confirmed
this stage:
- No Flutter/Dart SDK on `PATH` (`which flutter` / `which dart` resolve to
  nothing) — `flutter analyze`/`flutter test` could not be run.
- **Newly confirmed**: no Python backend environment either —
  `python3 -c "import fastapi"` raises `ModuleNotFoundError`, and `pytest`
  is not installed (`pip show pytest` reports not found). Backend tests
  added this stage (`test_stage15_constraints.py`'s three new tests) were
  written and checked for syntactic validity only (`ast.parse` on every
  touched backend file passed), not actually executed.

All verification this stage was manual code reading and
cross-referencing of method signatures/call sites/Union wiring across the
three-layer (dataclass/schema/router) plus two-layer (Dto/controller)
constraint architecture. No on-device or emulator verification of any
visual or interactive change (AppBar layout, logo tap-through, midpoint
placement actually holding under drag, select-all → delete actually
succeeding) was possible in this sandbox.

## Known gaps / deferred

- Item 3's `point_line_distance` value of exactly `0.0` is unverified
  against the real py-slvs solver in this sandbox. If midpoint placement
  fails to converge on-device, try `0.001` instead (per the brief's own
  fallback suggestion) as the first thing to check.
- No new test coverage was added on the Flutter side for Item 3 (the
  rewritten `_materializeMidpoint`) or Item 4 (`selectAll`/
  `deleteSelected`'s constraint-inclusion fix) — `sketch_controller_test.dart`
  has no existing coverage of either path (consistent with Stage 20's
  documented gap for the midpoint path specifically). Worth adding once
  the Flutter toolchain is available: a midpoint placement asserting both
  new constraints exist with the right type/value and the point holds on
  the line after a solve; a select-all → delete-all scenario on a sketch
  with at least one Line-level constraint (Vertical/Parallel/etc.)
  asserting it no longer 400s.
- `(b)` from Item 4's write-up above (constraint response DTOs not
  uniformly exposing their underlying Point ids) is a pre-existing gap in
  the wire format, not something this stage introduced or fixed — flagged
  here in case a future change wants `deleteSelected()` to do automatic
  transitive constraint cleanup instead of relying on `selectAll()` to
  over-select.
- No real on-device verification of any change this stage (AppBar tap
  navigating to the DIDSA website, the dark logo rendering correctly
  against the light AppBar, midpoint geometry actually holding under a
  drag, select-all → delete-all actually succeeding end-to-end) — every
  claim above is based on manual code reading only.

## Branch / commits

Branch: `claude/prompt-item-1-camera-gvbptx`. Commit pending as of this
doc's writing — see the branch's actual commit log for the final message.
