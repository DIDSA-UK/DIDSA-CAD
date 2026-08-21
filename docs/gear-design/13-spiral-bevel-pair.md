# Workstream 13 — Spiral bevel gear pair (`BevelPairFeature`, spiral variant)

Read `00-conventions.md` first, then `12-spiral-bevel-gear.md` (the
single-gear feasibility/scoping doc this one depends on), then
`11-bevel-pair.md` (straight bevel pairing — real, shipped, and the
direct source of every lesson section below). This is a
feasibility/scoping doc, one step before implementation, mirroring
`12-spiral-bevel-gear.md`'s own "pre-spike" framing — it proposes what to
build and what to spike first, not a finished, buildable design.

**Depends on Workstream 12's own Spike A landing first** (does the
layered-azimuthal-offset-on-Tredgold construction actually preserve
conjugate action between two independently-built mating gears — `12-
spiral-bevel-gear.md`'s own single biggest open question). If Spike A
rejects that construction, the sections below that assume it — "What
carries over," most of "What's new" — need re-checking against whatever
approach replaces it; the lessons section does not depend on the
construction approach and survives regardless.

## Lessons from `BevelPairFeature` (straight bevel), applied here

`11-bevel-pair.md`'s own real build-and-ship history (not its original
scoping text, which undersold this — see that doc's own corrected
"Interference checking" section) surfaced concrete, hard-won lessons.
Restating them here as design constraints for this workstream, not just
history:

1. **A fix checked only in the direction it targets can create a new
   problem in the opposite direction.** The straight-bevel balanced
   profile-shift fix (intruder `-X`, receiver `+X`, exploiting a real
   backlash-neutral identity) was correct for the direction it targeted,
   but applied unconditionally it could grow the receiver's own addendum
   enough to flip *it* into intruding from the other side — a real
   regression (`maximum_receiver_profile_shift_for_mesh_clearance`'s own
   docstring), caught only when the user tested a non-default pressure
   angle (14.5°, not the shipped default of 20°) on-device, not by this
   codebase's own test suite in advance. **Applies here doubly**: spiral
   bevel's own interference surface is two-dimensional (radial *and*
   tangential/azimuthal — see "What's new" below), not the one-dimensional
   radial-only surface straight bevel has, so there are more axes for an
   isolated fix to inadvertently break. Any auto-resolution move this
   workstream adds must re-check *both* members' margins in *both*
   dimensions after applying a candidate fix, not just re-verify the one
   direction/dimension the fix targets.

2. **The "obvious" quantity to check can be wrong — verify against real
   geometry, not textbook formulas.** Straight bevel's own margin system
   originally reasoned about `root_cone_angle` (the nominal, dedendum-
   derived root); real on-device testing found it has ~0% measured effect
   on real interference in the common case, and `tredgold_base_colatitude`
   (where the involute construction floor *actually* sits, which can
   differ from the nominal dedendum root) was the quantity that tracked
   real overlap. This was found by testing multiple hypotheses against
   real `BRepAlgoAPI_Common` measurements, not by reasoning from the
   formula alone. **Applies here**: `12-spiral-bevel-gear.md`'s own
   "Bearing on `BevelPairFeature`" analysis states the existing radial
   margin math "*plausibly* survives unchanged" for a spiral pair — that
   word is load-bearing. Treat it as an untested hypothesis, not a design
   decision, until Spike A confirms it the same way straight bevel's own
   margin system was calibrated (below).

3. **A predictive pure-math proxy needs continuous calibration against
   real OCCT measurement, with an explicit safety buffer.**
   `MESH_MARGIN_SAFETY_BUFFER_DEGREES = 0.5` exists because straight
   bevel's own margin proxy's zero-crossing isn't pixel-perfectly aligned
   with the real measured overlap's own zero. Whatever margin proxy this
   workstream builds (radial, tangential, or a combined check) needs the
   same treatment: build real spiral pairs, measure real
   `BRepAlgoAPI_Common` overlap across a sweep, calibrate the proxy
   against those measurements, add a buffer sized off the actual observed
   gap between predicted and measured zero — not trust a closed-form
   margin formula as exact on the first derivation.

4. **A balanced/backlash-neutral fix is a genuine mathematical identity
   when the shared quantities allow it, not just a tuning knob — but that
   has to be proven, not assumed.** Straight bevel's balanced profile
   shift works because `module`/`pressure_angle` are shared pair-level
   fields, making the receiver's new tooth thickness land exactly on the
   intruder's new gap width for any shift magnitude — checked
   algebraically, not just observed to look right. If this workstream's
   own auto-resolution field turns out to be something spiral-specific
   (spiral angle magnitude, a tangential phase offset — see "Proposed
   auto-resolution" below), check for an equivalent identity before
   assuming a naive 50/50 split is neutral; it usually isn't without one.

5. **Test across the parameter space before calling a fix done, not just
   the shipped defaults.** The straight-bevel over-correction bug was
   invisible at the pair's own default settings and only surfaced when a
   user tried a real, foreseeable non-default pressure angle. This
   workstream's own auto-resolution logic needs deliberate parameter
   sweeps as part of its own test suite from the start — multiple spiral
   angles, both hands of spiral, multiple pressure angles, multiple
   tooth-count ratios and shaft angles — not just the one canonical
   example pair, and not added only after a user finds the gap on-device.

6. **Keep planning docs synced to what actually ships, as it ships.**
   `10-bevel-gear.md`/`11-bevel-pair.md` drifted stale relative to the
   Tredgold rewrite and the mesh-margin system for real development time
   before anyone caught it, purely because nothing forced a doc update
   when the code changed underneath it. Whoever implements this
   workstream should update this doc's own status as construction
   evolves — including, honestly, if Spike A rejects the construction
   this doc currently assumes — not treat it as a one-time snapshot the
   way its two predecessors were.

## What carries over from straight `BevelPairFeature`

Per `12-spiral-bevel-gear.md`'s own "Bearing on `BevelPairFeature`"
section (moved and expanded here, since this is now that section's own
dedicated doc): `_tilted_basis` (apex-aligned dual-axis positioning) and
`pitch_cone_half_angles`-based auto-derivation of `gamma_1`/`gamma_2` are
both pure pitch-cone geometry, independent of lengthwise tooth shape, and
both remain valid for intersecting-axis spiral bevel (not hypoid, same
caveat `12-spiral-bevel-gear.md` already carries for the single-gear
case). The shared pair-level vs. per-member field split (module/pressure
angle/shaft angle/backlash/face width shared; tooth count/profile shift
per-member) has no obvious reason to change either — spiral angle and
hand of spiral are new per-gear-type fields on `BevelGearFeature` per
`12-spiral-bevel-gear.md`'s own entry-screen proposal, and the same
question this section exists to answer (shared vs. per-member) applies to
them too — see "Proposed fields" below.

## What's new: hand-of-spiral compatibility and tangential meshing

Two real, new-to-this-workstream problems, neither anticipated by
anything straight bevel's own margin system does:

- **Hand-of-spiral compatibility between mating members.** Two spiral
  bevel gears only mesh correctly with *opposite* hands (one left, one
  right) at the same nominal spiral angle magnitude — a purely
  tangential/azimuthal concern with no counterpart in the existing
  radial-only margin system. This is closer to a hard validation rule
  (reject/warn on a same-hand pair) than a margin to auto-resolve, but
  needs a real decision: hard `422` at create time, or a non-blocking
  warning banner matching `00-conventions.md`'s own "warn, don't block"
  convention for everything else in this doc set? Lean toward the
  warning-banner convention for consistency, but this is exactly the kind
  of call `12-spiral-bevel-gear.md`'s own Spike A should confirm is even
  physically necessary (vs. "wrong but still buildable, just not
  functionally meshing") before committing to blocking behavior.
- **Tangential (along-the-tooth) meshing failure** — the specific class of
  problem the Tredgold rewrite exists to prevent for straight bevel
  (two independently-built flanks with no guaranteed conjugate-action
  relationship). The existing straight-bevel margin system checks
  radial/colatitude overlap only; it was never designed to catch a
  tangential failure, because straight bevel's own Tredgold construction
  makes tangential conjugate action a *guarantee*, not something that
  needs runtime checking. Spiral bevel's own layered-offset construction
  (`12-spiral-bevel-gear.md`'s proposed approach) does *not* yet have
  that same guarantee proven — that's exactly what Spike A tests. If
  Spike A finds the guarantee holds (two mating members with matching
  spiral-angle magnitude and opposite hand are *always* conjugate by
  construction, the same way two Tredgold-built straight-bevel members
  are), this workstream inherits that guarantee for free and needs no new
  runtime tangential-margin check, only the hand-of-spiral input
  validation above. If Spike A finds the guarantee is approximate or
  parameter-dependent, this workstream needs its own tangential margin
  proxy — a real, separate piece of new math, not an extension of
  anything in `bevel_math.py` today, and calibrated per lesson 3 above.

## Proposed auto-resolution field(s)

Straight bevel's own `profile_shift: float | None` (`None` = auto,
"explicit always wins" — `BevelPairMemberSpec`'s own convention, itself
mirroring `RackFeature.backing_height`) is the established pattern for
"a pair-level problem gets a per-member sentinel field with a computed
default." Two candidates for this workstream, not yet decided between:

- **`profile_shift` again, unchanged.** If the radial margin system
  really does carry over unchanged (lesson 2's open question), the same
  field and the same `resolve_member_profile_shifts` logic could resolve
  radial interference for a spiral pair exactly as it does today — no new
  field needed for that dimension.
- **A new field for tangential/phase alignment**, if Spike A finds the
  layered-offset construction's conjugate-action guarantee is
  parameter-dependent rather than automatic. Shape TBD — possibly a
  small azimuthal phase adjustment analogous to profile shift's radial
  one, but this doc deliberately does not invent that field's exact
  semantics ahead of Spike A's result, per lesson 2's own warning against
  designing against an unverified hypothesis.

Whichever field(s) this resolves to, the resolution algorithm itself must
apply lesson 1 directly: after computing a candidate auto-fix, re-check
*both* members' margins in *every* dimension the fix could plausibly
affect (not just the one it targets) before accepting it, capping the fix
the way `maximum_receiver_profile_shift_for_mesh_clearance` caps the
straight-bevel receiver's own step, rather than applying it
unconditionally.

## Verification plan

Mirrors this project's own real history on this exact feature, not a
generic "write tests" placeholder:

1. **Spike A itself** (from `12-spiral-bevel-gear.md`, extended to pairs
   specifically): build real two-member spiral-bevel candidates via the
   layered-offset construction and directly measure interference/backlash
   via `BRepAlgoAPI_Common`, across a real parameter sweep — multiple
   spiral angle magnitudes, both hands (confirming a same-hand pair
   actually fails to mesh, not just "looks wrong"), multiple pressure
   angles, multiple tooth-count ratios and shaft angles. This is the
   direct extension of the exact test that drove the original Tredgold
   rewrite, and gates every design decision in this doc above it.
2. **A committed regression test locking in a real non-default case**,
   the same shape as `test_bevel_pair_auto_profile_shift_still_avoids_
   interference_at_a_low_pressure_angle` (`tests/test_bevel_pair_feature.
   py`) — added *because* a user found a real gap the shipped default case
   didn't cover, and now permanently guards it. Don't wait for an
   equivalent on-device report before this workstream's own test suite
   covers its analogous non-default cases; add the sweep from item 1 as
   real committed tests up front, per lesson 5.
3. Calibrate any new margin proxy's own safety buffer against the actual
   observed gap between predicted and measured zero-crossing (lesson 3),
   documented in that proxy's own docstring the way `MESH_MARGIN_SAFETY_
   BUFFER_DEGREES`'s own docstring documents its source.

## Explicitly deferred

Mirrors `11-bevel-pair.md`'s own deferred list, plus one item specific to
this workstream:

- **Hand-of-spiral pair-compatibility UX beyond a basic warning/error** —
  e.g. a visual indicator of hand mismatch in the preview — real later
  work, not designed here.
- **DXF flat-pattern export** — already out of scope for straight bevel
  entirely (`docs/dxf-io/00-conventions.md`'s "Bevel flat-pattern DXF"
  note, `11-bevel-pair.md`'s own corrected section), doubly so for a
  curved spiral trace, which compounds the "unroll a cone flat" problem
  `12-spiral-bevel-gear.md` already flags for the single-gear case.
- **Hypoid bevel pairing** — offset, non-intersecting axes; a separate,
  even-further-later phase not bundled with spiral/Zerol pairing, mirrors
  `12-spiral-bevel-gear.md`'s own hypoid deferral for the single-gear
  case.

## Complexity/risk

Contingent on `12-spiral-bevel-gear.md`'s own Spike A result, in either
direction: if Spike A confirms the layered-offset construction is
conjugate by construction (the optimistic case), this workstream may be
*lower* risk than `11-bevel-pair.md` was relative to `10-bevel-gear.md` —
positioning/cone-angle derivation genuinely carries over unchanged (see
above), and no new tangential-margin math would be needed, only
hand-of-spiral input validation and (possibly) reusing the existing
radial profile-shift system as-is. If Spike A finds the guarantee is only
approximate, this workstream needs a genuinely new tangential margin
proxy calibrated from scratch (lesson 3) — real, unbudgeted new math, not
just wiring. Either way, do not assume this workstream is "just wiring,
the way pairing was easy once the single-gear spike landed" without
Spike A's own result in hand — `11-bevel-pair.md`'s own original
complexity assessment made exactly that kind of assumption (calling
interference checking a non-issue) and turned out wrong once real
on-device testing happened; this doc's own "Lessons" section exists
specifically so that mistake isn't repeated here.

## Spike findings (2026-08-21) — Spike A's result, and what it means for pairing

Spike A landed — see `12-spiral-bevel-gear.md`'s own matching dated
entry for the full method/measurements. Short version: **NO-GO on
"conjugate by construction."** The layered-offset construction, corrected
to actually produce a spiral trace (12's own §2), reduces exactly to
Tredgold at β=0 but leaves a real, small-but-nonzero residual interference
(~7-9% of a tooth's own volume at moderate spiral angles, for the one
representative geometry tested — 10T/10T, module 4, pressure angle 20°,
shaft 90°) that meshing-phase adjustment alone cannot remove, plus a sharp
breakdown at high spiral angle (≥~35° in that same geometry) and at
extreme tooth-count-ratio splits. This is the **pessimistic branch** this
doc's own "What's new" section named in advance ("if Spike A finds the
guarantee is approximate or parameter-dependent, this workstream needs its
own tangential margin proxy"), not the optimistic "inherits the guarantee
for free, only needs hand-of-spiral input validation" branch. Both open
questions this doc's own "What's new" section posed are now answered:

### 1. Hand-of-spiral compatibility — confirmed real and physically necessary, not just a labeling convention

Directly measured (12's own §3 "Same hand vs. opposite hand" table,
β=10°/20°/30°, same 10T/10T pair): same-hand overlap is worse than
opposite-hand at every β tested (105.8 vs. 82.4 mm³ at 10°; 137.3 vs. 77.9
at 20°; 168.1 vs. 71.9 at 30°), and the *gap* between them widens with β
(23 mm³ → 96 mm³) rather than staying a fixed offset. This confirms the
physical necessity this doc's own "What's new" section asked Spike A to
settle before committing to blocking behaviour.

**On the hard-422-vs-warning-banner question this doc posed**: the
measured magnitudes here (11-18% of a tooth's own volume even at the
moderate β tested, growing with spiral angle, on a construction that
*already* has its own real residual in the correctly-paired opposite-hand
case) argue for leaning toward the warning-banner convention this doc
already favoured, at least for now — a same-hand pair's interference isn't
categorically different in *kind* from the opposite-hand residual
already measured, just reliably worse in *degree*, and doesn't (in the
cases tested here) make `BRepAlgoAPI_Common` itself fail the way the
broken v1 construction's same-hand cases did (`12-spiral-bevel-gear.md`'s
own §1: `IsDone()` returning `False` outright). That said, this was
checked only up to β=30° on one tooth-count ratio; the widening-gap trend
means a hard reject may become the safer default once larger spiral
angles are actually offered as a real user-facing range — re-check this
call once `BevelGearFeature`'s own spiral-angle field has real bounds.

### 2. Radial mesh-margin math — confirmed to survive unchanged, and now for a provable reason, not just "plausibly"

`12-spiral-bevel-gear.md`'s own §4: `offset(R)`/`curve(R)` are pure
rotations about the gear axis and change nothing else, so
`bevel_pair_mesh_margin_degrees`/`tredgold_base_colatitude` (both
colatitude-only) are provably untouched by the spiral extension — not an
empirical hope, a direct consequence of which coordinate the new math
touches. The pressure-angle sweep (128.3→77.9→28.3 mm³ across
14.5°/20°/25°) independently confirms this holds in practice, tracking the
same direction/shape as the existing straight-bevel calibration
(`MESH_MARGIN_SAFETY_BUFFER_DEGREES`'s own docstring). **This doc's own
lesson 2 ("the 'obvious' quantity to check can be wrong — verify against
real geometry") is satisfied in the *reassuring* direction this time**:
the existing radial system needs no changes and no re-calibration.

### 3. What this means for "Proposed auto-resolution field(s)"

Given §2's confirmation, the first candidate this doc proposed
("`profile_shift` again, unchanged" for the radial dimension) is settled:
**yes, reuse it unchanged** — `resolve_member_profile_shifts` and its
whole existing bisection-search apparatus need no modification for the
radial component of a spiral pair.

The second candidate ("a new field for tangential/phase alignment") is now
**required, not speculative** — §1's confirmed pessimistic branch means a
spiral pair genuinely needs a new mechanism for the residual
`12-spiral-bevel-gear.md`'s §3 characterized. Concrete shape, building
directly on what this session measured: a new margin proxy calibrated
against real `BRepAlgoAPI_Common` sweeps the same way
`MESH_MARGIN_SAFETY_BUFFER_DEGREES` was (lesson 3), most likely keyed off
the meshing-phase offset (12's own §3 phase-sweep found a real, narrow
local optimum near but not exactly at the existing straight-bevel
convention — a per-pair search over a small phase window, capped the same
defensive way `maximum_receiver_profile_shift_for_mesh_clearance` caps its
own step per lesson 1, is a more promising starting shape than a
closed-form formula given how sharply the phase sweep's minimum sits next
to a 100× collision wall). This is real, unbudgeted new math — budget it
as such, not as wiring on top of the existing radial system.

### 4. Lesson 5 applied directly — the parameter sweep this doc asked for, done

Per this doc's own lesson 5 ("test across the parameter space before
calling a fix done"), `12-spiral-bevel-gear.md`'s own §3 already swept
multiple spiral angle magnitudes, both hands, multiple pressure angles,
multiple tooth-count ratios, and multiple shaft angles — not just the one
canonical case — specifically to avoid repeating the straight-bevel
over-correction gap this doc's own lesson 5 describes. The tooth-count-
ratio sweep is the one that surfaced a real, unanticipated failure mode
(8T/16T and 6T/24T breaking down catastrophically, correlated with a
steep pitch-cone-angle split) that a single-canonical-pair check would
have missed entirely — direct vindication of testing the sweep up front
rather than waiting for an on-device report.

### 5. Go/no-go for this workstream

Per this doc's own "Complexity/risk" framing ("if Spike A finds the
guarantee is only approximate, this workstream needs a genuinely new
tangential margin proxy calibrated from scratch... real, unbudgeted new
math, not just wiring"): that is exactly where this lands. Positioning
(`_tilted_basis`/`pitch_cone_half_angles`-derived cone angles) and the
radial profile-shift system carry over unchanged and need no new
work — genuinely lower-risk than they might have been. But this
workstream cannot proceed to a real `BevelPairFeature` spiral variant
without first landing the new tangential margin proxy §3 calls for, and
without `12-spiral-bevel-gear.md`'s own Spike B (fold-risk at high spiral
angle / extreme tooth-count ratios) landing first — both are real,
separate pieces of work this spike surfaced but did not itself complete.
