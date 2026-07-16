# DIDSA-CAD Sketcher — Restructure Plan (revised 2026-07-16)

**Status: near-term, active priority.** This is the current problem, and it stays the current problem — fixing it is what turns DIDSA-CAD into something distributable to friends, colleagues, and on-site engineers. Long-term platform ideas (`docs/didsa-longterm-vision-and-model.md`) inform this plan where relevant (§6) but do not delay it.

**This is the one-time, deliberate revision the original version of this plan called for.** Both pre-restructure spikes (`docs/sketcher-spikes-ffi-and-plane-sketch.md`) have now reported real, on-device-verified **Go** verdicts — not the ambiguous or negative outcomes the original plan's phasing was hedged against. That changes the shape of this plan substantially, not incrementally: §2's central decision flips, several phases below are superseded rather than merely re-sequenced, and one item that was explicitly parked as long-term-only is promoted into this plan's own scope. Everything here is written against those actual verdicts, per the spike doc's own closing instruction ("worth writing the revised plan against whichever combination actually lands rather than guessing now").

This document still answers the open questions in `docs/sketcher-architecture-ux-scoping.md` §16 and turns its §15 options menu into decisions and a phased plan. It assumes that document as read — round-trip counts, entity/constraint mechanics, and the drag-system deep dive aren't repeated here.

---

## 1. Diagnosis (unchanged)

Scoping doc §16 Q1 asked whether the complaint is speed, predictability, or correctness. Reading the evidence in that document together:

- **Latency and predictability are the same complaint, not two.** The dragged point's own position is server-echoed rather than locally rendered, and the rest of the sketch only reflows on a throttled (≤ once/120ms) round trip. "How things resolve when moving them around" is exactly what that architecture produces — motion that's correct but never quite immediate, and occasionally jumps to a different valid solution branch on a big single move.
- **Correctness bugs (Slot's redundant-constraint fragility, Polygon's multi-round fix history) are a related but separable structural issue** — both trace to the same root cause named in §13: a split-brain architecture where the client caches and the backend computes, and every edit path has to remember to re-sync. Slot is the worse case because, unlike Polygon (now a real backend entity as of 2026-07-14), it has no backend identity at all.

Nothing about this diagnosis changed. What changed is that there's now a confirmed, on-device-verified way to remove the root cause directly (§2) rather than only mitigate its symptoms.

## 2. Decision (revised): adopt an in-process FFI solver — reusing the real solver, not reimplementing it

The original version of this section rejected "a full client-side solver" and that specific idea — **reimplementing** py-slvs's constraint solving from scratch in Dart — stays rejected, for exactly the reasons already given: reproducing every sign/ambiguity workaround, the tangent/equal-radius virtual-line trick, Spline's cubic-Bezier tangent continuity, and Slot's redundancy handling from zero, in a second language, with real risk of reintroducing bugs already fixed server-side.

**But that is not what Spike A tested or confirmed, and conflating the two would be a mistake.** Spike A embeds the actual SolveSpace C++ solver core — the same code `py-slvs` already wraps, already debugged, already carrying every one of those workarounds — in-process on the client via Dart FFI. Confirmed for real on the actual test device (Galaxy S23 Ultra / Adreno 740), not just argued for:
- A clean `arm64-v8a` NDK cross-compile of the exact pinned SolveSpace fork.
- A small (27-function), precisely-bounded `extern "C"` shim over the fork's own `System` C++ class — the same class the backend's Python bindings already call through, not a reimplementation of its bookkeeping.
- **Exact parity at the raw solver level** for both a simple case and Slot specifically — the single hardest, most fragile case in the current system — confirmed against the real backend's own `solve_sketch`.
- Real `dart:ffi` loading and solving inside a genuine release APK on the device.

This directly removes the root cause named in §1, rather than mitigating it: if the actual constraint solving runs in-process, there is no server round trip to decouple rendering from (Phase 1, below, is superseded rather than merely improved), and the split-brain client-caches/backend-computes architecture (§13 of the scoping doc) stops being split at all for the interactive path.

**One real, load-bearing risk this decision inherits, found during the spike and not to be glossed over:** a layer of interpretive business logic — the specific set of "redundant-but-actually-fine" constraint-type combinations that are safe to treat as converged, and the provisional-DOF floor that compensates for a known py-slvs undercounting quirk — currently lives in Python (`backend/app/sketch/solver.py`), not in the raw solver itself. Porting the constraint-construction calls to Dart is not sufficient on its own; this interpretive layer has to be ported too, or a fresh Slot (and anything else relying on the same redundancy pattern) will report incorrect `converged`/`dof` status even though the underlying geometry solves correctly. This is now a precisely scoped, well-understood porting task (not a research question — see the spike doc's Track 1 verdict for the exact logic), but it is real work, not a footnote.

**Licensing is accepted, not a remaining gate.** GPL-3 is accepted and the repository is being open-sourced to satisfy it (see the spike doc's licensing findings) — Google Play is the confirmed clean distribution path; the Apple App Store is not viable near-term for reasons specific to Apple's own store terms, unrelated to this plan's technical scope.

This decision is adopted, not parked — the cheaper-options-first framing the original §2 used no longer applies, since the "expensive" option turned out not to be expensive in the way that mattered (no reimplementation, no reintroduced-bug risk at the solver level).

## 3. Decision (new): adopt plane-embedded 3D sketching, sequenced after the solver migration, not bundled into it

Spike B also reported a real, on-device-confirmed **Go**: B1 (tap → ray → `hitTestReferencePlanes` → place a point, under `OrbitCamera`) felt right on-device after one real bug fix (a pinch-zoom-direction inversion, since fixed and confirmed — a bug in the test harness's own gesture mapping, not in `OrbitCamera`); B2 (`OrthographicProjection`/`OrthographicCamera`, `flutter_scene`'s own documented extension point) rendered and picked correctly under orthographic with zero changes needed to the hit-testing code.

This was previously parked in `docs/didsa-longterm-vision-and-model.md` §13 as aspirational, explicitly gated behind confirming the orthographic camera wasn't a hard blocker — it no longer is. **Promoted from long-term-aspirational to confirmed-feasible-and-schedulable.**

**Deliberately not bundled into the same restructure push as §2's solver migration, even though both are now "Go."** The reasoning is about what problem each one actually solves: §2 is a direct fix for §1's diagnosed complaint (latency/predictability/correctness). Plane-embedded 3D sketching does not address that diagnosis at all — the flat 2D canvas's drag latency and Slot's redundancy are not caused by it being 2D rather than 3D-embedded. It's a separate, independently valuable upgrade (unified camera/interaction with Orbit View, richer 3D context while sketching) that happens to have been de-risked in the same spike round. Sequencing it after the solver migration, as its own deliberately scheduled initiative rather than folded into "the sketcher restructure," keeps this plan focused on the problem it was written to solve and avoids a bigger, riskier combined rewrite (new interaction model *and* new solving architecture at once) when the two can land independently, exactly as the spike doc's own framing anticipated ("solver location and sketch dimensionality are separate questions... either can land without the other").

If you'd rather sequence these the other way, or run them in parallel, that's a legitimate call — this is a recommendation to confirm, not a unilateral resequencing, same posture the original plan took toward its own Prompt-sequencing question (§5 below).

## 4. Phased plan

### Phase 0 — Round-trip reduction (do first, no design decision required; unchanged)
Free, low-risk wins already identified in scoping doc §15.4:
- Replace `_refreshAllPoints`'s per-point `GET` loop with the single `listPoints` call the mid-drag refresh already uses elsewhere in the same file.
- Collapse the finish tail's separate `solve` / `points` / `constraints` / `profile` calls into one combined response for the common "just finished a mutation" case.

No architectural risk, ships immediately regardless of §2/§3's sequencing, and directly benefits the backend's own `/solve` endpoint, which stays in active use for non-interactive purposes (initial load, save-time validation, any context the in-process solver doesn't cover — see Phase 1's own open question below) even after interactive solving moves client-side.

### Phase 1 (revised) — Port the FFI solver into the real client app
**Supersedes the original Phase 1** ("decouple the dragged point's on-screen tracking from the round trip"). That phase existed to make an inherently server-round-tripped interaction *feel* more instant by rendering speculatively and reconciling later. If the actual solver runs in-process, there is no round trip in the interactive path to reconcile against — the original Phase 1's entire mechanism (speculative local render + periodic server reconciliation) doesn't apply. Building it now, only to remove it once Phase 1 (this version) lands, would be wasted work.

Concretely, this phase turns Spike A's throwaway on-device harness (`client/lib/viewport3d/b1_tap_test_screen.dart` is the *plane-sketch* prototype, not this one — the FFI harness lived in a separate, already-deleted scratch project, per the spike doc's Track 1 verdict) into real, shipped code:
1. Build the real Dart-side `extern "C"` shim + FFI bindings as part of the actual client app (not a throwaway project) — the spike already did this once; this repeats it as production code, including the `-static-libstdc++` link fix the spike found (a genuine, documented gotcha, not optional polish).
2. Write the Dart equivalent of `backend/app/sketch/solver.py`'s `_PySlvsBuilder` — a `SolverBuilder`-shaped wrapper around the shim's ~27 functions, mirroring `constraints.py`'s existing `Constraint.add_to_solver` dispatch so the constraint-construction logic doesn't need reinventing, just retargeting.
3. **Port the redundancy-safe-type override and provisional-DOF floor** from `solver.py` (see §2's risk note above) — this is not optional; skipping it means a Dart-solved Slot reports wrong `converged`/`dof` status even though its geometry is correct.
4. Land this behind one narrow, real interaction path first (recommend: a single Point drag on a simple sketch, the same shape Spike A's parity check already used) and confirm on-device before widening to the full constraint vocabulary — the spike's two test cases are deliberately not "everything," and neither is this rollout.
5. Once confirmed, decide what changes for the backend's `/solve` endpoint: does it stay as the source of truth for save/load/non-interactive validation (recommended default, since Phase 0's optimizations and the existing test suite already depend on it), or does responsibility shift entirely to the client with the backend only persisting already-solved state? This is a real open design question, not decided here.

Only after this phase actually ships does Phase 3 (Slot) and Phase 4 (scoped re-solve) below make sense to schedule, since both depend on knowing where interactive solving actually lives.

### Phase 2 (new, sequenced after Phase 1 per §3) — Plane-embedded 3D sketch
Turns Spike B's confirmed prototype into the real sketch tool:
1. Implement `OrthographicProjection`/`OrthographicCamera` as real client code (the spike's version, in `client/lib/viewport3d/b1_tap_test_screen.dart`, is a working reference already verified on-device — expect to lift it close to as-is, not redesign it).
2. Build real sketch-entity creation on top of the confirmed tap → ray → `hitTestReferencePlanes` → place-a-point mechanic, extending from "one point" to the actual tool vocabulary (lines, circles, arcs, etc.) — full parity was explicitly out of scope for the spike and stays a real scoping task here, not assumed free.
3. Decide, deliberately, whether this replaces the flat 2D canvas outright or coexists with it (e.g., as an alternate mode) — the spike's own go/no-go criteria left this as "a UX tradeoff worth your explicit call," and B1/B2 both passing doesn't answer it by itself.
4. Sketch coordinates living in a plane-embedded 3D space (rather than a flat local `(x, y)`) has real, not-yet-worked-out implications for anything downstream that currently assumes flat 2D — profile detection, OCCT wire construction, and (if Phase 1 has landed by then) how the in-process solver's own 2D workplane concept maps onto a 3D-embedded plane. Scope this explicitly before starting, rather than discovering it mid-implementation.

### Phase 3 (revised) — Give Slot a real backend entity
Mirrors Polygon's now-completed treatment (2026-07-14): atomic server-side creation in one call instead of ~9–11, and a genuine backend identity enabling the same kind of drag-reinterpretation Polygon gets via `_polygonForVertex`.

**The original motivation for this phase — eliminating the Tangent/EqualRadius redundancy that requires `REDUNDANT_OKAY` special-casing — is now lower-priority, not gone.** Spike A's parity check didn't just confirm the redundancy exists; it confirmed the current handling of it is *correct* and *precisely characterized* (see §2's risk note and the spike doc's Track 1 verdict for the exact override logic), where before it was closer to a hard-won-but-still-somewhat-empirical special case. A from-scratch constraint-set redesign to avoid the redundancy structurally is still worth doing if convenient, but it is no longer defusing a poorly-understood ticking time bomb — it's simplifying something already known to work. Don't let that redesign block giving Slot a real backend identity, which is the actual prize (atomic creation, drag-reinterpretation) and stands on its own regardless of whether the constraint set itself is ever redesigned.

If Phase 1 has landed by the time this starts, decide whether "Slot's real backend entity" needs a client-side (in-process solver) counterpart too, or whether the backend entity is sufficient for persistence/OCCT-generation purposes while the client's own in-process representation stays independent — don't assume the answer either way.

While in this territory: audit whether Rectangle's single-diagonal `AtMidpointConstraint` workaround and other shape tools have similar hidden redundancy. Lower priority than Slot itself — worth a pass, not worth blocking Slot on.

### Phase 4 (revised) — Scoped/partial re-solve, wherever interactive solving ends up living
`solve_sketch` currently re-solves the entire sketch on every call, regardless of what changed. `dof_analysis.dart` already computes connected-constraint-component clustering for DOF coloring — the same clustering can identify which points a given drag could possibly affect, informing a partial solve instead of a global one. **This idea's implementation location now depends on Phase 1's outcome**: if interactive solving moves to the client (the expected direction), this optimization belongs in the Dart-side solver wrapper, not the backend, since the backend's `/solve` endpoint may no longer be in the interactive hot path at all. Its value still grows with sketch size regardless of where it lives — worth doing once Phase 1 (and Phase 3, if sequenced first) are stable, before sketches get large enough for whole-sketch re-solve cost to become its own complaint.

### Phase 5 — Anchor-semantics enhancement (deferred, optional; unchanged)
Letting the user designate additional points as temporarily anchored during a drag (a "hold this corner still" gesture) — the existing `anchor_point_ids` mechanism already accepts a list, not just one id, so this is additive rather than architectural. Only pursue if the phases above leave a genuine "which geometry moves" predictability gap, as distinct from the latency gap Phase 1 targets.

### Explicitly not adopted / genuinely open right now
- **Reimplementing the solver from scratch in Dart** (the original, narrower reading of "full client-side solver") — still rejected, for the reasons in §2. FFI-embedding the real solver is a different thing and is what's actually adopted.
- **iOS.** Spike A's build-feasibility and licensing findings for iOS are research-only, not confirmed on real hardware or a real device — there is no physical iOS test device yet, and iOS distribution (the Apple App Store specifically) has its own unresolved licensing obstacle independent of this plan's technical scope. Treat Phase 1 as Android-only until iOS is separately de-risked.
- **A professional legal review of the GPL-3/anti-Tivoization/Google-Play-terms question.** The decision to accept GPL-3 is made; the specific legal read backing it is not yet reviewed by a professional, per the spike doc's own open item. Get this in front of someone before Phase 1 ships to real users, not before starting the engineering work itself.
- **Whether the flat 2D canvas gets fully replaced or coexists with plane-embedded 3D sketching** (§3, Phase 2 item 3) — explicitly not decided here.

## 5. Sequencing against other in-flight work

The original version of this section referenced "Prompt G (Sweep)" and "Prompt H" sequencing — that terminology no longer appears anywhere in `docs/roadmap.md`, so it's stale rather than still-accurate; whatever those prompts were has since completed, been renamed, or been superseded. Re-derive current sequencing against whatever `docs/roadmap.md` shows as active/next at the time Phase 1 actually starts, rather than trusting this document's now-outdated reference. The underlying rationale still holds, though, and is worth restating: every new sketcher feature built before Phase 1 lands inherits today's round-trip-based drag behavior, and building on top of Slot's current structural fragility only gets more expensive as the codebase grows around it. Phases 0–1 are bounded and independently gate-able, so prioritizing them isn't an open-ended detour from whatever else is in flight.

## 6. Phase gates

Same discipline as every other prompt in this project: status doc entry, CI green on amd64 and arm64, on-device confirmation before the next phase starts. Phase 1 and Phase 2 both need real on-device confirmation, not just CI — "does the drag feel instant" and "does tap-to-place still feel right in the real tool, not just the prototype" are not things a sandbox test can verify, a lesson already relearned once this session (both spikes' verdicts came from real hardware, not argument, and Track 2's zoom-direction bug was only found because of that).

## 7. Relationship to the long-term vision (revised)

`docs/didsa-longterm-vision-and-model.md` §13 covered 3D-native sketching as a genuine-but-gated long-term direction, explicitly not part of the near-term restructure. **That gate has now been cleared** — Spike B confirmed the orthographic-camera prerequisite §13 named directly, and Phase 2 above is that item, promoted from aspirational to scheduled. `docs/didsa-longterm-vision-and-model.md` §13 should be updated to reflect this promotion rather than continuing to describe it as a parked idea waiting on future de-risking; the de-risking already happened.
