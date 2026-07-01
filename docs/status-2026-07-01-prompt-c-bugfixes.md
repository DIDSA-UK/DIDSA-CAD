# Prompt C — on-device bug-fix round 1 — 2026-07-01

On-device testing of Prompt C (`docs/status-2026-07-01-prompt-c.md`) against
the manual test checklist surfaced three real bugs, all now fixed and
re-verified against the real `pythonocc-core`/`py-slvs` environment
bootstrapped for the original Prompt C work (see that doc's "Test/analyze
results" for how). All three trace back to a design decision that looked
sound on paper but didn't hold up against a real sketch/part.

| # | Report | Root cause | Fix |
|---|--------|-----------|-----|
| 1 | C1.3: overlapping inner loop doesn't error; extrude produces a partial/broken solid | Centroid-only containment isn't enough to validate a hole | `_loop_fully_contains` (full boundary + edge-intersection check), new `ProfileStatus.OVERLAPPING_LOOPS` |
| 2 | C2: disjoint-loop sketch never recognised as extrude-eligible | Client picker never learned about C2's new `multiple_loops` status | `ProfileDetectionDto.isExtrudable`, used by `_checkExtrudeEligibility` |
| 3 | C3: far-side edges bleed through solid geometry; highlighted faces show through the body | Edge bias scaled to the *whole mesh's* bounding-sphere radius, not the local feature it's near | `kEdgeDepthBias` reverted to a fixed, non-scaled world-space amount |

---

## 1 — Overlapping/touching inner loop produces a broken solid instead of an error

### Report
C1.3 test sketch: an outer rectangle with a smaller rectangle inside it,
but sharing one whole edge with the outer boundary (not fully interior).
Extrude did not show an error; the resulting solid had some faces
generated and some missing.

### Root cause
`_classify_nesting`'s only test for "is this loop a hole of that one" was
centroid containment (`_loop_contains_point` on the candidate's centroid).
That's necessary but not sufficient: a loop whose centroid is inside its
container can still have part of its own boundary sitting outside, or
exactly on, the container's boundary. The reported sketch is exactly this
case - the hole rectangle's bottom edge is coincident with the outer
rectangle's bottom edge. That loop sailed through classification as a
valid hole, and `extrude.py`'s `_face_for_profile` handed OCCT a wire that
isn't a genuine interior boundary of the outer wire - `BRepBuilderAPI_
MakeFace.Add` doesn't validate this for you, so the result is an
invalid/partial face (some triangles tessellate, some don't), not an
exception.

An initial fix attempt used vertex-only containment (every candidate
vertex must satisfy `_loop_contains_point` against the container) - this
did **not** catch the exact reported case: the standard even-odd ray-cast
algorithm classifies a point sitting exactly on a container edge as
"inside" for most positions along that edge (a known, correct property of
that algorithm, not a bug in it), so a hole that shares a whole edge with
its container still passed a vertex-only check. Caught by writing the
exact reported sketch as a test before considering the fix done - see
"Test coverage" below.

### Fix
- New `_loop_fully_contains(sketch, container, candidate)`
  (`backend/app/sketch/profile.py`): vertex-in-polygon containment **plus**
  a segment-intersection check (`_segments_intersect`, standard
  orientation-based test with an on-segment/collinear-touching case) between
  every candidate edge and every container edge. A shared/touching edge
  now fails this even though every vertex individually "contains."
  Circle-vs-polygon and circle-vs-circle cases use a point-to-segment /
  center-distance check instead (`_point_to_segment_distance`), since
  circles have no discrete edges to intersect.
- New `ProfileStatus.OVERLAPPING_LOOPS`, returned by `_classify_nesting`
  before a loop is accepted as anyone's hole - reported distinctly from
  `INVALID_NESTING` (hole-inside-a-hole) since the fix a sketch's author
  needs is different (redraw the loop inside its container, not remove a
  level of nesting).
- `extrude.py`/`document/router.py` needed no changes: `OVERLAPPING_LOOPS`
  was never added to `_EXTRUDABLE_STATUSES`, so it's already rejected the
  same way `BRANCH`/`NO_LOOP` are.

### Test coverage
- `test_stage2_profile.py`: a hole sharing a whole edge with its container
  is rejected as `OVERLAPPING_LOOPS`; a hole touching its container at a
  single corner is also rejected (confirms the fix isn't limited to the
  exact reported edge-sharing case).
- `test_stage9_extrude.py`: creating an Extrude on the reported sketch is
  rejected with a 400 containing `overlapping_loops` in the detail.
- Regression-checked against the existing fully-interior-hole tests (a
  hole with genuine clearance from its container) - unaffected, still
  `CLOSED_LOOP`.

---

## 2 — MultiProfile sketches never offered for extrude

### Report
C2 test sketch: two disjoint rectangles, no nesting. The Feature tree
picker showed "This sketch has no closed profile" and the long-press
Extrude action was disabled - despite the backend's `/profile` endpoint
correctly reporting `multiple_loops` (confirmed directly against the real
API).

### Root cause
This was a genuine gap in the original Prompt C work, not something that
regressed afterward: `_require_closed_sketch_feature`
(`backend/app/document/router.py`) was updated to accept `MULTIPLE_LOOPS`
for *creating* an Extrude, but the **client's own pre-check** -
`PartScreen._checkExtrudeEligibility`, shared by both the long-press menu
and the Prompt D picker - only ever looked at
`ProfileDetectionDto.isClosedLoop` (`status == 'closed_loop'`). Since this
client-side check runs *before* any create-Extrude request is ever sent,
a MultiProfile Sketch was rejected at the UI layer and the (already-fixed)
backend gate was never reached. The original status doc's claim that "the
Feature-tree extrude picker already just tries the create call and shows
the server's error on failure" was wrong - it pre-validates client-side
first, and that's the code path that needed updating.

### Fix
- `ProfileDetectionDto` (`sketch_api_client.dart`) gained
  `isExtrudable` (`closed_loop` **or** `multiple_loops`), matching
  `_require_closed_sketch_feature`'s gate exactly, alongside the existing
  `isClosedLoop` (left unchanged and still used by the sketch canvas's
  single-profile area fill, which only knows how to fill one area).
- `PartScreen._checkExtrudeEligibility` now checks `isExtrudable` instead
  of `isClosedLoop`.

### Test coverage
- `part_screen_test.dart`: long-pressing a SketchFeature whose `/profile`
  reports `multiple_loops` now shows the Extrude action enabled (mirrors
  the existing "no closed profile -> disabled" test with the opposite
  assertion). Like every `flutter_scene`-dependent test file in this
  sandbox, this cannot be executed here (see Prompt C's own status doc);
  verified with `flutter analyze` only.

---

## 3 — Far-side edges and highlighted faces bleeding through solid geometry

### Report
On a stepped/notched part (not a simple box), edges on the far side of the
part - which should be occluded by nearer solid geometry - rendered
visibly through the body. Also observed: a highlighted/selected face
showing through the body.

### Root cause
Prompt C's edge-bias fix (`kEdgeDepthBias`) was expressed as **0.1% of the
mesh's own bounding-sphere radius**, reasoning that a fixed world-space
value would be imperceptible on a metre-scale part and too heavy-handed on
a small one. That reasoning only accounted for the part's *overall* size,
not the depth of its *smaller local features* - a stepped/notched part's
overall bounding radius says nothing about how deep any one step or notch
actually is. For a part where a local feature's true depth is smaller than
0.1% of the whole part's bounding radius, the bias pushed that feature's
edges towards the camera by *more than the feature's own depth*, so a far
wall's edges ended up biased in front of a nearer wall and rendered
through it - a direct, mechanical explanation for "far side edges
incorrectly render," not a vague rendering glitch.

This plausibly explains the highlighted-face symptom too, even though
`buildHighlightFacesNode`/`_syncHoverNode`/the selection-highlight code
were never touched by Prompt C: `buildMeshEdgesNode`'s edges are drawn
**opaque** (`AlphaMode.opaque`) and therefore depth-*write* (confirmed by
reading `flutter_scene` 0.18.1's own `scene_encoder.dart`: the opaque pass
runs with `setDepthWriteEnable(true)`, while the translucent pass used for
face highlights - `AlphaMode.blend` - keeps depth *testing* enabled at
`lessEqual` but only disables writes). An oversized edge bias doesn't just
misplace the edge itself; by writing an artificially-close depth value at
its own pixels, it can corrupt what a later translucent-pass depth test
(e.g. a highlight overlay) sees at those same pixels. This is a plausible,
not confirmed, explanation - it could not be tested visually in this
sandbox (no GPU/display; `flutter test` can't even load
`flutter_scene`-dependent files here, per Prompt C's own status doc) - see
"Verification required" below.

### Fix
`kEdgeDepthBias` is back to a small **fixed world-space amount** (not
scaled to any per-mesh geometry property), matching the pre-existing,
already-shipped `meshEdgeNudgeAmount`'s magnitude (`0.02`) exactly - the
original z-fighting bug (before any of this session's changes) was
attributed entirely to that constant's *direction* (away from mesh center
instead of towards the camera), never its magnitude, so restoring the
magnitude while keeping the corrected direction is the most
evidence-based choice available without being able to re-tune it visually.

### Verification required
Since this can't be tested in this sandbox at all, please re-run C3.1-C3.4
and the "highlighted faces show through body" case on-device. If the
highlight issue persists after this fix, it's very likely a separate,
pre-existing bug unrelated to Prompt C (nothing in the highlight/hover
code path was touched by either the original Prompt C work or this fix)
and would need its own dedicated investigation into
`buildHighlightFacesNode`/`triangleHighlightBuffers`/`_syncHoverNode`.

---

## Test/analyze results

- Backend: `pytest tests/` - **252 passed**, 0 failed (was 249; +3 new
  tests for item 1's fix), run against the same real `pythonocc-core`/
  `py-slvs` environment as the original Prompt C work, not a stub.
- Client: `flutter analyze` on every file touched by this round (plus the
  whole-project run) - no new issues; the same 2 pre-existing, unrelated
  errors in `test/selection_list_drawer_test.dart` as before. `flutter
  test` on the new/changed test files hits the same pre-existing
  `flutter_scene`/`flutter_gpu` compile-time incompatibility documented in
  every prior prompt's status doc - not something this round introduced.
