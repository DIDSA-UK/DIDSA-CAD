# Sketch drag: the hybrid (formula proposes, constraints clamp)

Groundwork for the sketch track of the wish > solve design (`docs/constrained-drag-implementation-plan.md`, S10-S13). Written so the
per-frame clamp can later move from the local SolveSpace solver to a bespoke client-side projector (the goal: a client with no
GPL solver in it, e.g. for the iOS App Store) without touching the shape logic.

## What a drag does now

For the seven closed-form shapes (polygon, slot, circle, arc, ellipse, ellipse arc, rectangle), `SketchController.updatePointDrag`:

1. computes the shape's **proposal** from the cursor with its closed-form function (`_closedFormXGeometry`): a rigid, regular shape,
   no solver, no wrong roots;
2. if **no user constraint touches the shape**: applies the proposal directly (unchanged, fast path);
3. if a user constraint touches it **and a local solver exists** (`_hybridStructuralFor`): `_runHybridDragFrame` seeds the solve with the
   proposal, switches the shape's own *provisional* size constraints on at the sizes the proposal implies
   (`solveSketchLocally(provisionalDistances:)`), and soft-drags the grabbed point. Confirmed constraints clamp the result, so a
   constrained point **slides along the permitted path while the shape changes in real time**. A frame the solver or its guards
   reject is dropped (the shape stays at the last good frame).
4. with no local solver (Windows/iOS today): polygons use the general backend path, the other shapes keep the plain closed form.

Drop (`endPointDrag`) of a hybrid drag is the general one: sync reflowed points (the *wish*), `_solveAndTrackDof(anchor)` (the backend
solve and DOF/rigidity come back), one undo entry restoring every point. The pre-grab rules apply: over-constrained and
fully-constrained points refuse the grab (`rigidity.isPointFullyConstrained`, the narrow per-point test).

## "User constraint" = anything that is not structural

The backend lists, per shape, the constraints it created only to give the shape its form (`structural_constraint_ids` on every shape
response, derived from the entity's own `*_constraint_id(s)` fields, plus nested entities: a slot's arcs, a polygon's reference circles).
The client keeps them per entity (`_structuralConstraintIds`, `SketchPolygonView.structuralConstraintIds`). Any other constraint
referencing the shape's points or lines is a user constraint. A vertex/rim drag never moves the centre, so centre-only constraints
(grounded on the origin, dimensioned to other geometry) are ignored for it; a centre drag counts them. A shape whose structural ids
were never learned counts as having none (plain closed form) - a safe default.

## Where to change things for the next steps

* **Replace the clamp** (bespoke lightweight solver / wish > solve projector): `_runHybridDragFrame` -> `_trySolveDuringDragLocally` is the
  only place the hybrid depends on SolveSpace. The proposal, structural-id classification, pre-grab rules, drop protocol and undo are
  solver-independent.
* **Fewer round trips**: the per-frame path makes none; the drop makes the same calls as the general path (PATCH reflowed points, solve).
* **Mobility oracle / authoritative DOF** (S12): would replace `rigidity.isPointFullyConstrained` in the pre-grab rules.
* **Smoothing**: frames the guards reject are simply dropped; the `_trySolveDuringDragLocally` guards (blow-up, arc branch, residual) are
  the continuity tests to generalise.

## Tests

`client/test/sketch_controller_test.dart`, group "hybrid drag" - real solver (host build, see `client/native/slvs/CMakeLists.txt`), one
per shape family; each fails if the hybrid is switched off.
