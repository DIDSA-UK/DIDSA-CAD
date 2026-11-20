# Sketch rigidity: spec (parity follow-ups F6)

Normative for DIDSA-VR's per-entity constraint colours (`scripts/design_table/sketch_rigidity.gd`, parity follow-ups F7; decision 8 of
DIDSA-VR `docs/parity-followups-investigation.md`). The reference is the flat app's `client/lib/sketch/dof_analysis.dart`
(`SketchRigidity.analyze`, `describeConstraint`, `dofCostByConstraintType`), built by `SketchController.rigidity` and read by
`sketch_canvas.dart` to colour each line, circle, arc, ellipse, spline and point. A port reproduces
[`sketch-rigidity-vectors.json`](sketch-rigidity-vectors.json) (section 6). As with the drag projector, VR writes its code from this text
and the vectors, not by translating the Dart.

It is a **topological count**, not a solve: union-find clusters of points joined by constraints, each constraint removing a fixed
number of degrees of freedom by type. Fast (no geometry is read; positions do not matter), exact about connectivity, approximate about
redundancy (section 5). The backend's solve stays the authority for the whole sketch (its `dof` and convergence, section 4).

## 1. Inputs

| Input | Meaning (what the flat app passes) |
|---|---|
| `point_ids` | every point of the sketch (the origin included) |
| `fixed` | the origin and every locked point (`is_locked` from the last solve; a Fix constraint's points arrive this way) |
| `lines` | Line id -> (start point id, end point id), every line |
| `constraints` | the sketch's constraints, backend wire form (as `GET …/constraints` returns them) |
| `trust_converged_solve` | the backend's **last solve converged** (`solve.converged`); false before any solve |

## 2. Each constraint's points and cost

A `distance` with `provisional: true` is **skipped** entirely (a shape tool's placeholder size, which the solver skips too). Every other
constraint gives a type and a list of point ids (in this order; a Line id missing from `lines` contributes no points, its other points
stay):

| `type` | Points | Cost |
|---|---|---|
| `distance` | `point_a_id`, `point_b_id` | 1 |
| `vertical`, `horizontal` | `point_a_id`, `point_b_id` (not `line_id`) | 1 |
| `coincident` | `point_a_id`, `point_b_id` | 2 |
| `concentric` | `center1_point_id`, `center2_point_id` | 2 |
| `angle`, `parallel`, `perpendicular`, `equal_length`, `line_distance` | `line1_id`'s start, end, `line2_id`'s start, end | 1 |
| `collinear` | the same four | 2 |
| `point_line_distance`, `point_on_line` | `point_id`, `line_id`'s start, end | 1 |
| `at_midpoint` | `point_id`, `line_id`'s start, end | 2 |
| `tangent` | `center_point_id`, `radius_point_id`, `line_id`'s start, end | 1 |
| `curve_tangent` | `center1_point_id`, `center2_point_id`, `shared_point_id` | 1 |
| `equal_radius` | `center1_point_id`, `radius1_point_id`, `center2_point_id`, `radius2_point_id` | 1 |
| `spline_tangent` | `segment_a_p0` … `segment_a_p3`, `segment_b_p1` … `segment_b_p3` (seven: **not** `segment_b_p0`) | 1 |
| `point_on_circle` | `point_id`, `center_point_id`, `radius_point_id` | 1 |
| `point_on_ellipse` | `point_id`, `center_point_id`, `major_point_id`, `minor_point_id` | 1 |
| `arc_length` | `center_point_id`, `start_point_id`, `end_point_id` | 1 |
| `horizontal_angle` | `line_start_id`, `line_end_id` | 1 |
| `point_angle` | `vertex_point_id`, `point1_id`, `point2_id` | 1 |
| `line_circle_distance` | `line_start_id`, `line_end_id`, `center_point_id`, `radius_point_id` | 1 |
| `circle_distance` | `center1_point_id`, `radius1_point_id`, `center2_point_id`, `radius2_point_id` | 1 |
| `point_circle_distance` | `point_id`, `center_point_id`, `radius_point_id` | 1 |
| `fixed`, any other type | no points | 0 (ignored) |

The costs are in the file's `dof_cost`. Duplicated ids in a list are harmless (a union with itself; the cost is per constraint).

## 3. The analysis

```
D = the descriptions of section 2 (provisional distances skipped), in input order
union-find U over point ids:  for each d in D: union(d.points[0], d.points[i]) for every i ≥ 1
removed[root] = Σ cost(d.type) over d in D with a non-empty point list, root = U.find(d.points[0])
for each id in point_ids that U has seen (named by some d):
    raw[root(id)] += (id in fixed) ? 0 : 2;     if id in fixed: grounded_root[root(id)] = true
for each id in point_ids that U has seen:
    remaining = raw[root] − removed[root]
    if remaining < 0 and not trust_converged_solve:  OVER ∋ id
    else if remaining == 0 and grounded_root[root]:   FULLY ∋ id
    if grounded_root[root]:                           GROUNDED ∋ id
pin union-find P: for each d in D of type coincident or concentric: union(d.points[0], d.points[i])
PINNED = fixed ∪ { id in point_ids : P has seen id and P.find(id) = P.find(f) for some f in fixed that P has seen }
```

Notes for a port:
* A point no constraint names (after skipping provisionals) is in no cluster: never fully, over, grounded or pinned (unless it is in
  `fixed`, which puts it in PINNED). A fixed point named by nothing grounds nothing.
* Points named by constraints but absent from `point_ids` join clusters (they link them) but add no raw freedom and get no verdict.
* The verdict is **per cluster**: every point of a cluster gets the same fully / over / grounded answer, the origin included when it is
  in one. Pinned is the exception: only points tied to a fixed point by coincident / concentric links.
* With `trust_converged_solve` nothing is over-constrained (a redundant but consistent set, such as a polygon's own chain plus a
  horizontal edge and an across-flats dimension, counts negative but converges); fully still needs remaining exactly 0.

Queries: `isPointFullyConstrained(p)` = p ∈ FULLY; `isPointOverConstrained(p)` = p ∈ OVER; `isPointGrounded(p)`; `isPointPinned(p)`;
`isAnyPointGrounded` = GROUNDED is not empty; `isSegmentFullyConstrained(a, b)` = both fully; `isSegmentOverConstrained(a, b)` = either over.

## 4. Per-entity colours (what the flat app's canvas does)

Each entity is judged from its **defining pairs** (`sketch_canvas.dart`):

| Entity | Defining pairs |
|---|---|
| line | (start, end) |
| circle | (centre, radius point) |
| arc | (centre, start), (centre, end) |
| ellipse | (centre, major tip), (centre, minor tip) |
| ellipse arc | (centre, major), (centre, minor), (centre, start), (centre, end) |
| spline | every consecutive pair of through points |
| point, text | the point itself (a text: its anchor point) |

* **Over-constrained (red)**: any pair is over (`isSegmentOverConstrained`), **or** any of the entity's points is *forced
  over-constrained*: named by a constraint the last solve reported failed (`solver_reported_failed_constraint_ids`, its points as in
  section 2), or an endpoint of a line that is both horizontal and vertical, or of either of two lines that are both parallel and
  perpendicular. (A spline checks its through points for the forced case.)
* **Fully constrained (green)**: the **whole sketch** is fully constrained, or every pair is fully constrained
  (`isSegmentFullyConstrained`; a point: `isPointFullyConstrained`). The whole sketch is fully constrained when it has geometry, the
  backend's last solve converged with `dof ≤ 0`, and `isAnyPointGrounded`.
* Otherwise unconstrained.

Order on a line: grabbed, selected, hovered, **over**, construction, **fully**, unconstrained (so red shows on construction geometry,
green does not). Circles and other curves the same without "grabbed". A point: grabbed, the tool-in-progress highlights, forced
over-constrained (red; exactly the points a grab refuses), selected, hovered, fully (whole sketch or the point). A plain point's red
comes only from the forced sources, not from the count. The colours themselves are each app's own.

The vectors' `entities` give the rigidity part of this rule only (over / fully / free from the pairs); the backend sources and the
whole-sketch override are the caller's, from its last solve.

## 5. As built: what the count gets wrong

* **Redundancy is counted, not detected.** A consistent but redundant set (two equal heights on a rectangle, a polygon's chain plus a
  horizontal edge and an across-flats dimension) counts negative and reads **over** until a solve converges (`scene-rectangle-over-dimensioned`,
  `hexagon-horizontal-and-across-flats`); `trust_converged_solve` then clears it. Conversely a redundant constraint can hide a missing
  one and read **fully** while one freedom is left: the count cannot tell.
* **Per cluster.** One missing dimension anywhere in a connected structure leaves every line of it uncoloured (`scene-rectangle-missing-height`);
  separate structures are judged separately (`scene-rectangle-and-free-line`). It says which *structure* still needs something, not which
  line.
* **Costs are the solver's equation counts**, not geometry: an `equal_radius` tying an arc's end to its start leaves the end one freedom
  (`scene-arc-one-end-free`), a circle whose only size is provisional keeps its radius point free (`scene-circle-provisional-radius`).
* A Fix constraint counts nothing itself; its points are grounded through `fixed` (the backend reports them locked).
* `spline_tangent` lists seven points (its `segment_b_p0` is the shared joint, normally `segment_a_p3`).

These are the flat app's behaviour; a port reproduces them.

## 6. Vectors

`docs/sketch-rigidity-vectors.json`, written by `client/test/sketch_rigidity_vectors_test.dart` from `client/test/support/sketch_rigidity_cases.dart`:
every input of `client/test/dof_analysis_test.dart` (27 cases, each with the assertions that test makes on it as `checks`) and seven
whole-entity scenes (rectangle with and without its height, with a free line, over-dimensioned; circle with a provisional and a
confirmed radius; an arc with one end free; part D types, a Fix and a spline tangency).

```
tools/sketch_vectors/export_rigidity.sh            # (re)write the file, then check it
tools/sketch_vectors/export_rigidity.sh --check    # exit 1 if a regeneration differs, or a case does not reproduce from the file
```

| Field | |
|---|---|
| `dof_cost` | section 2's costs by type |
| `input` | `point_ids`, `fixed`, `lines` (id -> [start, end]), `constraints` (wire form), `trust_converged_solve`, and for scenes `entities` (kind -> id -> defining points: line [start, end], circle [centre, radius point], arc [centre, start, end]) |
| `frames[0]` | the expected answer: sorted ids (of `point_ids` and `fixed`) in `fully`, `over`, `grounded`, `pinned`; `any_grounded`; scenes: `entities` kind -> id -> `over` / `fully` / `free` |
| `checks` | `dof_analysis_test.dart`'s assertions on the same input: `query` (`fully`, `over`, `grounded`, `pinned`, `segment_fully`, `segment_over`, `any_grounded`), `args`, `want` |

A port runs section 3 on `input` and compares the four sets and `any_grounded` exactly (no tolerance: there are no numbers), then each
entity's verdict by section 4's pair rule.
