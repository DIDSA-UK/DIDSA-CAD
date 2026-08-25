# Workstream 13 — Spiral bevel gear pair (`BevelPairFeature`, spiral variant)

## Status: done, backend and client — built directly on this doc's own Spike C

`BevelPairFeature` now has a real spiral variant, built directly against
this doc's own three 2026-08-21 spikes (and `12-spiral-bevel-gear.md`'s own
matching Spike A/B/C entries) - not a re-derivation. Everything below this
note (the original feasibility/scoping prose, the lessons section, and all
three "Spike findings" entries) is kept as historical record; read it for
the reasoning, but this note is what actually shipped.

- **Fields** (`app.document.models`): `BevelPairFeature.spiral_angle_
  degrees: float = 0.0` is **pair-level shared**, not per-member - the
  design call this doc's own "Proposed fields" section left open, made
  explicitly: both members physically mesh along one spiral trace, the
  same "arguably must share it" reasoning already applied to `module`/
  `pressure_angle_degrees`/`shaft_angle_degrees`/`backlash`/`face_width`.
  `BevelPairMemberSpec.spiral_hand: SpiralBevelHand = SpiralBevelHand.
  RIGHT` is **per-member** - the other half of that same design call: hand
  has to be representable per-member for a real hand-of-spiral *mismatch*
  to exist at all for `bevel_math.spiral_hand_mismatch_warning` to check.
  Both fields are `0.0`/meaningless-until-non-zero, mirroring `BevelGear
  Feature`'s own single-gear precedent exactly.
- **Construction** (`app.document.bevel_pair`): `_build_member_solid` now
  passes `spiral_angle_degrees`/`spiral_hand` straight through to `app.
  document.bevel._assemble_gear_solid`'s own already-shipped N-section
  spiral path (Workstream 12) - no new OCCT construction technique needed,
  exactly as this doc's own Spike C anticipated. The real new piece is
  `_search_meshing_phase`: `12-spiral-bevel-gear.md`'s own Spike C
  algorithm (coarse-grid pre-scan across a window of `+-(180 /
  tooth_count_2)` degrees, then a local golden-section refine within one
  grid step of the best point), implemented for real and wired into
  `resolve_bevel_pair_from_bodies` - runs only when `spiral_angle_degrees
  != 0.0` (a straight pair is untouched, byte-for-byte), gated by both the
  negative/`None`-overlap guard Spike C's own §1 found necessary
  (`GProp_GProps.Mass()` can return large-magnitude negative "no usable
  signal" readings on marginal geometry) and a coarser pre-check that skips
  the search entirely (falling back to the existing fixed-phase convention,
  with a warning) whenever either member's own baseline solid is already
  flagged marginal by `_assemble_gear_solid`'s own warnings.
- **Real OCCT verification** (`backend/tests/test_bevel_pair_feature.py`):
  a real parameter sweep, following the exact `BRepAlgoAPI_Common`
  methodology every spike in this thread has used - multiple spiral angles
  (0°/25°/45° on a 10T/20T pair, module 4, face_width 8), both resolvable
  tooth-count ratios this doc's own Spike C validated (10T/20T; 8T/16T,
  module 4, face_width 6), and a direct same-hand-vs-opposite-hand
  comparison isolated from the tooth-count-symmetric confound Spike C's own
  §1 identified. Confirms this doc's own Spike C conclusion directly
  against the real, committed implementation (not just a scratch harness) -
  real measured overlap is **exactly 0.0000 mm³** for 10T/20T at every
  tested angle (0°/25°/45°) and for 8T/16T at 20°, while a same-hand 10T/20T
  pair at 20° measures **30.49 mm³** of real interference against the
  opposite-hand pair's own 0.0 - a real, substantial, directly-measured
  degradation, not just the pure-math warning's own prediction. (The 8T/16T
  case also surfaces `bevel_pair_mesh_interference_warning` at exactly its
  own 0.5° safety-buffer boundary - a real, pre-existing radial-margin
  edge case for this specific tooth-count/face-width combination, unrelated
  to spiral and unchanged by it, per the provable-invariance argument
  below.) No new tangential margin proxy exists - the existing radial
  `bevel_pair_mesh_margin_degrees`/`MESH_MARGIN_SAFETY_BUFFER_DEGREES`
  system is reused completely unchanged, per this doc's own Spike C §4/§5
  revised conclusion.
- **Cost/timeout** (`client/lib/config.dart`): a spiral `BevelPairFeature`
  create/update call now gets its own, separately-raised request timeout
  (`ApiConfig.spiralBevelPairRequestTimeout`, 720s) instead of the blanket
  `documentRequestTimeout` (180s, already raised once for a plain Bevel
  Pair) - real headroom sized against Spike C's own on-device per-trial
  cost numbers (1-3s well-behaved, up to ~16s near/past a notch) times this
  implementation's own bounded ~33-trial eval budget
  (`app.document.bevel_pair._PHASE_SEARCH_GRID_POINTS`/`_PHASE_SEARCH_
  REFINE_ITERATIONS`), not a silently-absorbed risk.
- **Client** (`BevelDesignScreen`'s Bevel Pair mode): a pair-level "Spiral"
  `SwitchListTile` + numeric angle field (mirroring the single-gear
  toggle's own shape, `12-spiral-bevel-gear.md`'s shipped UX), plus a
  per-member "Hand of spiral" `SegmentedButton` inside each member's own
  section (defaulted to opposite hands, right/left, so a freshly-created
  pair meshes correctly out of the box) - the real UX work this doc's own
  "Out of scope for this UX proposal" note (in `12`'s doc) deferred to this
  workstream, now built.

**Explicitly still deferred, unchanged**: DXF flat-pattern export, true
Gleason envelope surfaces, hypoid, root fillet, and any UX beyond a basic
hand-of-spiral compatibility warning (e.g. a visual indicator of hand
mismatch in the preview).

---

*Everything below this point is the original feasibility/scoping doc plus
this workstream's own three 2026-08-21 spike-findings sections, kept as
historical record - the real implementation above is built directly
against these findings, not a re-derivation of them.*

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

### 6. Spike B landed (`12-spiral-bevel-gear.md`'s own matching entry) — one finding is this doc's own concern, not the single-gear workstream's

Spike B root-caused both of Spike A's own uncharacterized breakdowns.
Neither is the flank self-fold the "fold-risk" framing above anticipated
— `_flank_fold_warning` never fired in any case tested. The high-β
breakdown is a meshing-*phase*-convention artifact (directly fixable, see
12's own item 4); real, but a single-gear/pairing-positioning concern, not
specific to this doc.

**The tooth-count-ratio breakdown is different — it's a real, pre-
existing, non-spiral bug in `resolve_member_profile_shifts` itself**,
squarely this doc's own scope, not spiral bevel's at all. For a steep
tooth-count-ratio pair (6T/24T tested: γ≈14°/76°), the auto-balancing
logic computes a receiver correction approaching a full module
(`ps1=+0.9215` for that pair) — `maximum_receiver_profile_shift_for_mesh_
clearance` correctly caps this against *re-introducing interference*
(lesson 1's own concern), but nothing caps it against producing a
**geometrically malformed solid**: rebuilding that same member via the
real, unmodified, non-spiral `bevel._assemble_gear_solid` reproduces a
~4x analytic-vs-mesh volume disagreement (already correctly flagged by
`_assembly_sanity_warnings`'s own existing 2%-threshold check, just never
surfaced as a warning to the caller). `profile_shift=0` on the same
member agrees to <0.5% — the defect tracks the profile-shift magnitude,
not anything spiral-related.

This is a real defect in shipped, production `BevelPairFeature` today —
any straight (non-spiral) pair with a steep enough tooth-count-ratio split
would hit this via ordinary auto-resolution, not just as a spiral-bevel
edge case. It needs its own fix (cap `maximum_receiver_profile_shift_for_
mesh_clearance`'s own search against geometric malformation, not only
against re-introduced interference — the same "check every direction a
candidate fix could break, not just the one it targets" lesson 1 already
states, just for a dimension neither this doc nor `11-bevel-pair.md`'s own
real history anticipated: *solid validity* itself, not interference).
Independent of, and does not block, this workstream's own spiral-specific
go/no-go above.

**Fixed.** `bevel_math.bevel_tooth_tip_thickness` (Tredgold's own virtual-
spur-gear substitution plus a new `gear_math.tooth_thickness_at_radius`,
the standard involute tooth-thickness-at-any-radius relation generalizing
`tooth_thickness_at_pitch`) detects exactly this - a self-crossing,
negative-thickness tip - and `MINIMUM_TIP_THICKNESS_COEFFICIENT` (0.05x
module, calibrated against real `_assemble_gear_solid` builds across
three tooth counts) is now wired into `maximum_receiver_profile_shift_for_
mesh_clearance`'s own bisection alongside the existing reverse-margin
check: a trial shift must clear both to be accepted. Verified on-device
that the 6T/24T case now builds with no volume-disagreement warning and
the default/14.5-degree cases are unchanged.

## Spike findings (2026-08-21) — Spike C: the tangential margin proxy, and a real correction to why the residual exists

Real investigate/prototype pass answering this doc's own §3 ("build a real,
calibrated tangential margin proxy... the same treatment `MESH_MARGIN_
SAFETY_BUFFER_DEGREES` got for straight bevel"), using `12-spiral-bevel-
gear.md`'s own matching Spike C entry's real per-build phase search to
produce the phase-corrected baseline this item's own task asked for.
Explicitly investigation/validation, not a `BevelPairFeature` spiral-variant
implementation pass. Same real conda-forge `pythonocc-core` 7.9.3 env,
same scratch-only-harness convention, same re-derived N-section spiral
assembler (validated byte-for-byte against Spike A's own azimuth table -
see 12's own matching entry).

**Headline result, ahead of the detail below**: this session's own broader
parameter sweep - specifically, testing tooth-count ratios other than the
symmetric 10T/10T/20T/20T pairs every prior spiral-bevel spike measured
exclusively - found that the "phase-corrected residual" Spike A and Spike
B both measured and treated as an intrinsic, spiral-specific property of
the layered-offset construction is **not**, in significant part, a spiral
effect at all. It is almost entirely explained by a **pre-existing,
non-spiral structural property of Tredgold-approximated bevel pairs with
equal tooth counts**, newly surfaced by this session (not by Spike A/B,
which never tested an asymmetric ratio's own real overlap). Once that
confound is removed (tested on a tooth-count ratio the existing radial
system can actually fully resolve), real measured overlap is **exactly
0.0 mm³ at every spiral angle tested, 0° through 65°, at default phase,
opposite hand** - no detectable independent tangential residual above the
noise floor anywhere in this session's own testing. Per this project's own
established convention for a finding that contradicts a prior spike's own
numbers (`10-bevel-gear.md`'s own §7, `12-spiral-bevel-gear.md`'s own
Spike B §5): named explicitly, not silently overridden or silently agreed
with. Spike A's and Spike B's own measurements are not wrong as
measurements - the same 10T/10T configuration, rebuilt this session,
reproduces overlap in the same 30-50 mm³ range they both reported - this
session's own contribution is a different, better-supported explanation
of *why* that residual exists, found by testing a wider slice of the
parameter space this doc's own lesson 5 already calls for.

### 1. The mechanism: a symmetric tooth-count pair cannot fully resolve both directional margins with a single balanced shift - not a bug, a structural property

`resolve_member_profile_shifts`'s own balanced fix (intruder `-X`,
receiver `+X`) targets whichever *one* of the two directional margins
`worst_bevel_pair_mesh_margin_degrees` finds worse at baseline. For a
tooth-count-symmetric pair (`tooth_count_1 == tooth_count_2`, same
module/pressure angle/shaft angle), both directional margins are
*identical* at baseline (`margin_2_into_1 == margin_1_into_2` exactly, by
symmetry) - there is no genuinely "worse" direction to distinguish, only
a tie the code's own `<=` comparison breaks arbitrarily. Fixing the
chosen direction (shrinking the "intruder" member's own addendum) by
construction *requires*, for the balanced/backlash-neutral identity this
doc's own lesson 4 already established, growing the "receiver" member's
own addendum by the same amount - but for a symmetric pair the receiver's
own outgoing margin is the *identical* formula in the *identical* starting
state, so growing its addendum degrades its own outgoing margin by
exactly the improvement the intruder's fix bought, point for point. This
is provable directly from `bevel_pair_mesh_margin_degrees`'s own linear
form (`shaft_angle - (face_cone_angle + base_colatitude)`,
`face_cone_angle` monotonic increasing in `profile_shift`) - not merely
observed. `maximum_receiver_profile_shift_for_mesh_clearance`'s own
existing code already handles this *correctly*, defensively: its own
`is_safe_at(receiver_geometry.profile_shift)` check (the receiver's own
*baseline*, before any shift) fails immediately for a symmetric pair
whose baseline margin was already below the buffer - by this function's
own docstring, "returns `receiver_geometry.profile_shift` unchanged... a
pre-existing problem this function isn't responsible for fixing, only for
not making worse" - so the receiver genuinely gets **zero** correction,
and its own outgoing margin (and, this session found, the real measured
overlap in that direction) stays at exactly its unfixed baseline value.
**This is not a bug to patch** - it is a real, provable, mathematical
consequence of what a single shared shift value can do for two
*identical* mating members, confirmed on-device (10T/10T, module 4, face
width 8, pressure angle 20°: `resolve_member_profile_shifts` gives
`ps1=0.0, ps2=-0.6355`, and `worst_bevel_pair_mesh_margin_degrees` on the
*resolved* geometry is still **-4.598°**, far below the 0.5° buffer -
member 1's own direction was simply never touched).

**Not silent in production today**: `bevel_pair_mesh_interference_warning`
reads the same post-resolution `worst_bevel_pair_mesh_margin_degrees` value
`resolve_bevel_pair_from_bodies` already computes, so this configuration
already surfaces a real, accurate, non-blocking warning
("member_2's tooth tip is predicted to intrude...") in shipped, production
`BevelPairFeature` today, for *any* equal-tooth-count straight bevel pair
whose baseline margin is already below the buffer (a 90° miter gear pair
being the most common real-world example) - a real, previously-undocumented
property of the existing pairing system worth naming for whoever next
touches it, but genuinely independent of spiral and already warned-of, not
a silent gap this workstream needs to fix. Named here per the same pattern
`12-spiral-bevel-gear.md`'s own Spike B §2 already established for a
different pre-existing defect ("this session's own testing surfaced it,
fixing it is out of this workstream's own scope").

### 2. Direct confirmation: once radial resolution actually succeeds, the "tangential" residual is exactly zero

Tested two tooth-count ratios where `resolve_member_profile_shifts` *can*
distinguish a genuinely worse direction (an asymmetric ratio breaks the
tie the symmetric case can't) and drive `worst_bevel_pair_mesh_margin_
degrees` to its own target - module 4, pressure angle 20°, shaft 90°,
opposite hand, real per-build phase search from `12-spiral-bevel-gear.md`'s
own matching entry:

| pair | radial margin after resolution | β=0° | β=10° | β=20° | β=30° | β=45° | β=55° | β=65° |
|---|---|---|---|---|---|---|---|---|
| 10T/20T (face_width 8) | 0.500° (target hit exactly) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 |
| 8T/16T (face_width 6) | 0.498° (target hit) | 0.0 | - | 0.0 | - | - | - | - |
| 10T/10T (face_width 8, symmetric - for contrast) | -4.598° (receiver un-fixed, §1) | 43.8 | 43.7 | 43.2 | 42.3 | 36.2 | - | 32.1 |

(All overlap figures mm³, `BRepAlgoAPI_Common`, default phase for the
resolvable pairs since the true optimum already sits there - see below.)

Every resolvable-ratio overlap is **exactly 0.0 mm³**, at every β tested
including well past this doc's own matching entry's own notch-adjacent
range, at **default phase** - the real per-build search (item 1) wasn't
even needed to reach zero here, though it was run and confirmed the same
result. The symmetric 10T/10T case's own residual, by contrast, tracks
`12-spiral-bevel-gear.md`'s own Spike A/B numbers closely (this session's
own rebuild: 43.8 mm³ at β=0°, matching Spike B's own reported 50.6 mm³
for the same configuration reasonably closely) and shows the same mild,
real, *decreasing*-with-β trend both prior spikes found (43.8 → 32.1 mm³,
β=0° → 65°) - a small, genuine, secondary shape effect of the curved
lengthwise trace on the exact 3D interference volume (not captured by the
colatitude-only radial margin, which `12`'s own §4 already proved is
exactly β-invariant), but an order of magnitude smaller than, and
overshadowed by, the symmetric-pair radial-resolution gap it was
previously conflated with.

**Off-target radial resolution (asymmetric ratio, but at a pressure angle
where the existing caps still engage) also stays explained by the
existing system alone**, no extra spiral term needed - 10T/20T,
face_width 8, β=20°, opposite hand:

| pressure angle | radial margin | measured overlap (mm³) |
|---|---|---|
| 14.5° | -1.466° | 23.50 |
| 17.0° | -0.117° | 1.03 |
| 20.0° | 0.500° | 0.00 |

Directly comparable in shape to `MESH_MARGIN_SAFETY_BUFFER_DEGREES`'s own
straight-bevel calibration reference point (a margin around -0.4° leaving
"a small (~4 mm³) measured residual" for a 20T/40T straight pair) - this
session's own -0.117° → 1.03 mm³ point is proportionally consistent (both
imply roughly single-digit mm³ per tenth of a degree of margin shortfall)
with that existing, unchanged calibration, not a different relationship
spiral introduces.

### 3. Hand-of-spiral: a real, separate, large effect - confirmed independent of the radial-resolution confound

Re-ran the same-hand-vs-opposite-hand comparison on the *resolvable*
10T/20T pair specifically to isolate this from §1's own confound (Spike
A's own original same-hand measurement used the symmetric 10T/10T pair,
so its own magnitude was mixed with the radial-resolution gap too):

| β | opposite-hand overlap (mm³) | same-hand overlap (mm³) |
|---|---|---|
| 10° | 0.0 | 4.59 |
| 20° | 0.0 | 30.86 |
| 30° | 0.0 | 72.38 |

A clean, uncontaminated signal: opposite-hand stays exactly zero (matching
§2 above) while same-hand grows real, substantial interference that
increases with β - the *same* qualitative shape Spike A's own §3 found
(worse at every β, gap widening with β), now demonstrated on a baseline
with no other confounding residual at all. This settles this item's own
"does the [margin] proxy need its own hand-of-spiral validation baked in"
question cleanly: **no** - hand-of-spiral is a real, large-magnitude,
purely azimuthal effect entirely orthogonal to the (now confirmed
unnecessary, see §4) tangential margin question, and stays exactly what
this doc's own existing "What's new" section already concluded: a simple,
separate `hand_of_spiral` compatibility check (compare the two members'
own fields, warn or reject on a mismatch), not something a margin
function needs to compute a magnitude for. This session's own cleaner
numbers reinforce, rather than revise, this doc's own existing lean
toward the warning-banner convention over a hard `422`.

### 4. What this means for "Proposed auto-resolution field(s)": no new field needed

This doc's own §3 (Spike A/B's own conclusion) called a new tangential/
phase-alignment field "required, not speculative." This session's own
broader-ratio testing revises that conclusion, per this project's own
"self-correct and flag honestly" precedent: **no new field, and no new
margin proxy, is needed for the tangential dimension.** The existing
`bevel_pair_mesh_margin_degrees`/`MESH_MARGIN_SAFETY_BUFFER_DEGREES`/
`worst_bevel_pair_mesh_margin_degrees` system, completely unchanged,
already predicts real spiral-pair interference correctly - not merely
"the radial component of it" (this doc's own §2, already settled), but
the *entire* real measured overlap, once (a) `12-spiral-bevel-gear.md`'s
own real per-build phase search is applied and (b) the pair's own
tooth-count ratio is one the existing radial system can actually resolve
(most real pairs; the symmetric-ratio case is a real, known, already-
warned exception - §1). No independent spiral-driven residual was
detectable above the noise floor in any case this session tested, across
two tooth-count ratios and a β range spanning 0° to 65°.

This is a stronger, more useful outcome than a calibrated buffer would
have been, and it satisfies this doc's own lesson 3 ("a predictive proxy
needs continuous calibration against real OCCT measurement... not trust a
closed-form margin formula as exact on the first derivation") in the most
direct way possible: the calibration sweep this item's own task required
*is* the evidence that no new formula is needed at all, not a step taken
on the way to deriving one. `profile_shift` (already settled, this doc's
own §3) remains the only auto-resolution field a spiral pair needs -
unchanged from straight bevel, in both dimensions, not just the radial
one.

### 5. Go/no-go

**GO on reusing the existing radial mesh-margin system unchanged, with no
new tangential margin proxy** - the outcome this doc's own §3 called
"required, not speculative" is revised, on this session's own real,
multi-ratio on-device evidence, to "not needed": once a real per-build
phase search (`12-spiral-bevel-gear.md`'s own matching Spike C entry)
resolves meshing phase and the pair's tooth-count ratio allows the
existing `resolve_member_profile_shifts`/`bevel_pair_mesh_margin_degrees`
machinery to do its job, real measured overlap is zero, exactly as it
already is for straight bevel. Hand-of-spiral remains a real, separate,
confirmed-necessary check (§3) - a simple field-compatibility warning, not
a margin computation. **Separately, out of this workstream's own scope**
(same pattern as `12-spiral-bevel-gear.md`'s own Spike B §2): flag the
newly-found symmetric-tooth-count-ratio structural gap in
`resolve_member_profile_shifts`/`maximum_receiver_profile_shift_for_mesh_
clearance` (§1) to whoever next revisits straight-bevel pairing - real,
already partly mitigated by the existing (accurate) interference warning
firing for it today, not a silent defect, but worth a documented named
limitation or a real fix (e.g. widening the balancing search to also
consider an *unequal* split when a pair is tooth-count-symmetric) since it
means even ordinary straight (non-spiral) equal-tooth-count bevel pairs
carry a small, real, currently-unresolved residual today.

**Combined with `12-spiral-bevel-gear.md`'s own matching Spike C
conclusion (GO on the per-build phase search, with a flagged real cost
risk near/past the notch): both pieces this session was scoped to
validate land with a real GO.** Real `BevelGearFeature`/`BevelPairFeature`
spiral-variant implementation is the next, different workstream - building
it is not started here, per this session's own explicit scope.
