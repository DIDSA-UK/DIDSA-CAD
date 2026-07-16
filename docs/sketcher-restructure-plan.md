# DIDSA-CAD Sketcher — Restructure Plan

**Status: near-term, active priority.** This is the current problem, and it stays the current problem — fixing it is what turns DIDSA-CAD into something distributable to friends, colleagues, and on-site engineers. Long-term platform ideas (`docs/didsa-longterm-vision-and-model.md`) inform this plan where relevant (§6) but do not delay it.

This document answers the open questions in `docs/sketcher-architecture-ux-scoping.md` §16 and turns its §15 options menu into decisions and a phased plan. It assumes that document as read — round-trip counts, entity/constraint mechanics, and the drag-system deep dive aren't repeated here.

---

## 1. Diagnosis

Scoping doc §16 Q1 asked whether the complaint is speed, predictability, or correctness. Reading the evidence in that document together:

- **Latency and predictability are the same complaint, not two.** The dragged point's own position is server-echoed rather than locally rendered, and the rest of the sketch only reflows on a throttled (≤ once/120ms) round trip. "How things resolve when moving them around" is exactly what that architecture produces — motion that's correct but never quite immediate, and occasionally jumps to a different valid solution branch on a big single move.
- **Correctness bugs (Slot's redundant-constraint fragility, Polygon's multi-round fix history) are a related but separable structural issue** — both trace to the same root cause named in §13: a split-brain architecture where the client caches and the backend computes, and every edit path has to remember to re-sync. Slot is the worse case because, unlike Polygon (now a real backend entity as of 2026-07-14), it has no backend identity at all.

These are treated below as parallel, independently gate-able tracks rather than one monolithic rethink — consistent with the project's existing staged-decomposition pattern (A1–A4, B1–B4, C1–C2).

## 2. Decision: no full client-side solver

§15.1's large option — reimplementing py-slvs's constraint solving in Dart — is **not adopted**. Reasoning already laid out in the scoping doc is decisive on its own: it means reproducing every sign/ambiguity workaround, the tangent/equal-radius virtual-line trick, Spline's genuine cubic-Bezier tangent continuity, and Slot's redundancy handling, from zero, in a second language, with real risk of reintroducing bugs already fixed server-side. The one thing that used to motivate client-side solving — DOF/constrained-status coloring — is already solved independently and correctly by `dof_analysis.dart`'s topological approach. There's no remaining reason to pay this cost.

This is parked, not deleted. If Phases 1–3 below don't resolve the complaint, it's worth revisiting — but only after the cheaper options have had a real chance.

## 3. Phased plan

### Phase 0 — Round-trip reduction (do first, no design decision required)
Free, low-risk wins already identified in §15.4:
- Replace `_refreshAllPoints`'s per-point `GET` loop with the single `listPoints` call the mid-drag refresh already uses elsewhere in the same file.
- Collapse the finish tail's separate `solve` / `points` / `constraints` / `profile` calls into one combined response for the common "just finished a mutation" case.

No architectural risk, ships immediately, benefits every later phase (smaller round trips make Phase 1's reconciliation cheaper too).

### Phase 1 — Decouple the dragged point's on-screen tracking from the round trip
The most direct fix for the named complaint. Today the dragged point's rendered position is always whatever the server last echoed back (§9). Instead: render the point locally from the raw cursor delta immediately on every pointer-move (as already happens, in a narrower form, for a confirmed Polygon vertex's "speculative local move" — §7's one deliberate exception), and reconcile against the server's response periodically (on the existing 120ms throttle) or on drop rather than on every tick. This targets exactly "the entity under your finger doesn't feel instant" without touching how the *rest* of the sketch reflows, which stays server-solved as today.

Open item to settle before starting: reconcile on every throttled tick (safer, more frequent snap-back if local and server diverge) vs. reconcile only on drop (smoother during the drag, one possible correction at the end). Recommend starting with reconcile-on-tick, since it matches the existing throttle cadence and keeps the change smaller.

### Phase 2 — Give Slot a real backend entity
Mirrors Polygon's now-completed treatment (2026-07-14): atomic server-side creation in one call instead of ~9–11, a genuine backend identity enabling the same kind of drag-reinterpretation Polygon gets via `_polygonForVertex`, and — the actual prize — a constraint set redesigned from scratch to avoid the Tangent/EqualRadius redundancy that currently requires `REDUNDANT_OKAY` special-casing and produced the 2026-07-14 "fully constrained too early" bug. Polygon's migration is a proven template for this exact move; Slot is next in line and was already flagged in §15.3 as "the single most concrete, scoped item this document surfaced."

While in this territory: audit whether Rectangle's single-diagonal `AtMidpointConstraint` workaround (§8.2) and other shape tools have similar hidden redundancy, per §15.3's second bullet. Lower priority than Slot itself — worth a pass, not worth blocking Slot on.

### Phase 3 — Scoped/partial re-solve
`solve_sketch` currently re-solves the entire sketch on every call, regardless of what changed (§4.1, §15.2). `dof_analysis.dart` already computes connected-constraint-component clustering for DOF coloring — the same clustering can identify which points a given drag could possibly affect, informing a partial solve instead of a global one. This is a backend-architecture change independent of the client/server split question, and its value grows with sketch size — worth doing once Phases 1–2 are stable, before sketches get large enough for whole-sketch re-solve cost to become its own complaint.

### Phase 4 — Anchor-semantics enhancement (deferred, optional)
Letting the user designate additional points as temporarily anchored during a drag (a "hold this corner still" gesture) — the existing `anchor_point_ids` mechanism already accepts a list, not just one id, so this is additive rather than architectural. Only pursue if Phases 1–3 leave a genuine "which geometry moves" predictability gap, as distinct from the latency gap Phase 1 targets.

### Explicitly not adopted right now
- Full client-side solver (§2 above).
- 3D-native/plane-embedded sketching — belongs to `docs/didsa-longterm-vision-and-model.md` §13, gated behind orthographic camera work, and none of Phases 0–4 above foreclose it.

## 4. Sequencing against Prompt G / H

Recommendation: **pause Prompt G (Sweep) after F's current gate and run Phases 0–2 of this plan before it**, then resume G/H. Rationale: every new feature built on today's sketcher inherits its drag behavior and, for Slot specifically, a standing structural fragility that gets more expensive to fix the more the codebase grows around it — not less. Phases 0–2 are also bounded and independently gate-able, so this isn't an open-ended detour; it fits the same phase-gate rhythm G and H already follow. This is a recommendation to confirm, not a unilateral resequencing — the alternative (interleave a phase between each of G/H's own sub-steps, or finish G/H first) is available if preferred.

## 5. Phase gates

Same discipline as every other prompt in this project: status doc entry, CI green on amd64 and arm64, on-device confirmation before the next phase starts. Phase 1 in particular needs real on-device confirmation, not just CI — "does the drag feel instant" is not something a sandbox test can verify.

## 6. Relationship to the long-term vision

`docs/didsa-longterm-vision-and-model.md` §13 covers 3D-native sketching directly; this plan deliberately doesn't touch it. Nothing here — decoupled drag rendering, a real Slot entity, scoped re-solve — commits the sketcher to staying a flat 2D surface forever; they're all solver/transport-layer changes that a future plane-embedded sketch would still need regardless of where its geometry ultimately lives.
