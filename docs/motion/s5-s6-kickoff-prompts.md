# S5 / S6 kickoff prompts

Both sessions need S3 and S4, which are merged (CAD PR #266 and #267, `main` at `1fca1db` or later). They run **in parallel and share no files**:
S6 lives in DIDSA-CAD (`client/`), S5 lives in DIDSA-VR. The only thing they share is the spec and the vectors in DIDSA-CAD:

* `docs/motion/projector-spec.md` (normative), `docs/motion/vectors.json` (61 cases, tolerance 1e-9)
* contract of record: `docs/constrained-drag-implementation-plan.md` §3, tracker rows S3/S4 (handoff notes and the JSON example)

Each session ticks its own tracker row in the CAD plan file at the end. Because they run in parallel, S5 (a VR PR) records its tracker
text in its PR description and the CAD row is updated by a one-line CAD docs PR; S6 edits the row in its own CAD PR. Whichever
merges second rebases the two-line tracker conflict by keeping both rows.

Give the S5 session access to **both** repos (VR is the working repo; CAD is read-only reference and the backend for the e2e).

---

## Prompt: S6 — Dart projector (repo DIDSA-CAD)

```text
Repo: DIDSA-UK/DIDSA-CAD (main, at or after 1fca1db). Implement session S6 of
docs/constrained-drag-implementation-plan.md (Dart projector). S0–S4 are merged. Do NOT start S7 (no UI change)
and do not touch DIDSA-VR / S5.

Start: read plan §1–§4, the S6 brief in §6 and the tracker rows S3 and S4 (contract JSON + handoff notes).
Then read docs/motion/projector-spec.md completely — it is normative — and skim tools/motion_vectors/generate.py
(the reference implementation the vectors were made from) and the head of docs/motion/vectors.json (constants, conventions).
Read investigation §E.3, §E.5 only if the spec leaves a question open. Don't re-derive findings.

Branch: use your designated branch; if its PR is already merged restart it from origin/main
(git fetch origin main && git checkout -B <branch> origin/main); do not stack on old history.

Do:
1. client/lib/motion/ (pure Dart, no Flutter imports, no dart:ui): se3 chart (pose_delta / apply_delta / screw_exp, atan2
   rotvec incl. near-π and small-angle series exactly as spec §5), follower-weighted Gram–Schmidt (§3), projector (§4),
   blender (§9), anchor acceptance (§7), re-anchor scheduler as a testable class with an INJECTED clock (§8), dof-change
   hysteresis (§10). Keep each class small and separately testable; state machines mirror the Python ones in generate.py.
   Use a tiny own Vec3/Mat3 (or package:vector_math if already a dependency) — no new heavy dependency.
2. MateMotionDto (+ request/response, member, chart, quality, diagnostics; nullable exactly as in the tracker S3 note:
   max_step / sigma_min / sigma_gap nullable, converged:false carries no basis/dof/members, `committed`) in
   client/lib/api/document_api_client.dart and a mateMotion(partId, occurrenceId, {transform, leverArm, commit}) call.
   Do NOT read the v0 alias fields `transform` / `free_twists` in the response (S9 deletes them).
3. Instrumentation hooks for investigation §H: request counters, per-frame projection timing, anchor accept/reject counts
   (plain counters object, no UI).
4. Copy or reference vectors.json for tests WITHOUT forking it: the test reads docs/motion/vectors.json from the repo root
   (path relative to the client package) so a regenerated file is picked up. If that path is impractical for `flutter test`,
   add a one-line script that copies it into client/test/fixtures/ and a test that fails when the copy differs.

Tests (flutter test): a golden-vector runner covering EVERY kind in vectors.json (gram_schmidt, project, hysteresis, blend,
blend_anchor, scheduler, accept_anchor, swing_sequence incl. summary numbers) to 1e-9, poses compared as matrices;
scheduler tests with the fake clock; DTO round-trip against the tracker's example JSON (converged and converged:false).
Exit: golden vectors pass to 1e-9, flutter analyze clean, no UI change.

Constraints: spec is the source of truth. If you believe the spec or a vector is wrong, do not silently diverge: write down
the case id, the numbers, and stop that item — report it in the PR description and the tracker note (the same vectors gate S5).
No unrelated refactors. Do not edit the spec/vectors in this session unless you found a real defect; if you do, change
generate.py, regenerate (python tools/motion_vectors/generate.py; --check must pass) and say so loudly.

Environment: Flutter SDK is usually missing in sandboxes (see plan §4). If you cannot install it, say so and list what
was only read; do not claim tests passed. Finish by ticking S6 in the tracker (branch/PR, handoff notes: public API of the
projector classes, anything S7 needs, deviations), a dated docs/status.md entry, commit on your designated branch, open a PR.
Say clearly what you ran versus only read.
```

---

## Prompt: S5 — VR adopts the contract (repo DIDSA-VR)

```text
Repo: DIDSA-UK/DIDSA-VR (main). Implement session S5 of DIDSA-CAD's docs/constrained-drag-implementation-plan.md
(VR adopts the contract). Attach/clone DIDSA-CAD read-only for the plan, spec, vectors and the backend. S0–S4 are merged
(CAD PR #266, #267). Do NOT start S6 (Dart) or S7+, and do not edit DIDSA-CAD files except the S5 tracker row (see end).

Start: read the plan §1–§4, the S5 brief in §6 and the tracker rows S3 and S4 (contract JSON, handoff notes, the list of things
VR's docs/backend-api-notes.md needs). Then read DIDSA-CAD docs/motion/projector-spec.md completely (normative) and skim
tools/motion_vectors/generate.py + the head of docs/motion/vectors.json. In VR read scripts/mates_tool.gd (constrain_drag,
project_motion, weighted_basis, _drag_loop, _sync_with_motion_model, _sync_with_solve, persist_pose), docs/backend-api-notes.md,
docs/constrained-drag-rollout.md, tests/e2e_mates_motion.gd. Don't re-derive findings.

Branch: use your designated branch; if its PR is already merged restart it from origin/main; do not stack on old history.

Do:
1. Projector v2 in GDScript per the spec (own file, e.g. scripts/motion/free_motion_projector.gd, static/pure where possible,
   no scene-tree dependency so it is unit-testable): follower-weighted Gram–Schmidt, projection onto the response basis, per-member
   screw exponential-map integration (spec §5, correct skew matrix!), blend (§9), anchor acceptance (§7, client-measured jump),
   re-anchor scheduler (§8; one request in flight), dof-change hysteresis (§10), converged:false = hold (§11).
   Lever arm from the grabbed mesh's AABB half-diagonal in the occurrence's local frame, sent as lever_arm; afterwards use the
   response chart.lever_arm. Replace the constant CONSTRAINT_LENGTH_MM = 100.
2. Consume the S3 contract: members / basis / chart / quality; per-frame apply to ALL group members (followers move on screen).
3. Persist via ONE `commit:true` request on release using the release-time wish (spec §12); one undo entry for all members;
   on converged:false / error nothing is stored, restore the pre-grab poses.
4. DELETE the legacy paths: _sync_with_solve, _motion_supported and the 404/405 fallback; stop reading the v0 alias fields
   `transform` and `free_twists` (CAD S9 removes them from the backend). One code path.
5. Update VR docs/backend-api-notes.md and docs/status.md (mate-motion request lever_arm/commit, group response, /solve now moves
   followers, quality.max_step semantics).

Tests: a Godot unit test running the golden vectors from DIDSA-CAD docs/motion/vectors.json (copy into tests/fixtures/ with a
note + a check that fails when the source differs, or read a path via an env var) covering every kind, to 1e-9, poses compared as
matrices — the same JSON gates the Dart port in S6. Update tests/e2e_mates_motion.gd against a REAL backend built from CAD main
(requests per drag, group follow, commit atomicity, converged:false hold, no alias fields used) and keep the existing VR suite green.
Exit: VR e2e green against the S3+ backend; report request counts for a 60-frame drag (expected ≈ 1 + one per 150 ms + 1).

Constraints: spec is the source of truth. If you believe the spec or a vector is wrong, do not silently diverge: record the
case id and numbers, stop that item, and report it (S6 runs in parallel against the same vectors). No unrelated refactors.

Environment: the backend needs the real OCCT + py-slvs stack (CAD backend/environment.yml; earlier sessions built it with micromamba
from conda-forge into env `cadtest`, py-slvs via pip) and Godot 4.7-stable headless
(github.com/godotengine/godot/releases/download/4.7-stable/Godot_v4.7-stable_linux.x86_64.zip). Both are gone in a fresh
container. Leave the repo clean (temporary secrets.cfg, generated .uid/.import files removed).
Finish by: docs/status.md dated entry in VR; open the VR PR; put the tracker text for S5 (branch/PR, handoff notes: files,
public API, request counts, deviations, what S9 may now delete on the VR side) in the PR description AND edit the S5 row in
DIDSA-CAD's plan via a one-line docs PR. Say clearly what you ran versus only read.
```

---

## Notes for the person kicking these off

* Known open item both sessions may notice (documented, not a blocker): the backend Gauss–Newton retraction overshoots the nearest point on curved mates
  (tracker S4 note). It shows up as a larger anchor step on the off-axis swing; the spec's blend and acceptance test are the client-side answer.
* Spec constants `SIGMA_GAP_LOW`, `GAIN_MIN`, the jump-reject factor and the `max_step` tolerance are uncalibrated. Both sessions expose counters;
  change a constant only by editing `generate.py`, regenerating and telling the other session.
* S7 (flat live drag) needs S3 + S6 and starts after the S6 PR merges; S9 (removal of v0 aliases) needs S5 merged.
