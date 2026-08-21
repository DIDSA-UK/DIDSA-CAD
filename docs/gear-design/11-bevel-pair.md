# Workstream 11 — `BevelPairFeature`: automated live bevel pairing

Read `00-conventions.md` first. Depends on `10-bevel-gear.md` — do not
start until that workstream's spike has confirmed the construction
approach.

## Status: done, but read this before trusting the rest of this doc

`BevelPairFeature` is live, including client UI (`BevelDesignScreen`'s
"Bevel Pair" mode). This doc's original scoping text below predates two
real additions it doesn't mention — most importantly, the "Interference
checking: not needed at all" line below is **no longer true** and is kept
only as historical scoping context; see the corrected section in its
place.

- **A real pairwise tooth-mesh interference/profile-shift system**
  (mostly in `bevel_math.py`/`bevel_pair.py`) — see the corrected
  "Interference checking" section below for what it actually does.
- **A tooth-mesh close-up preview** ("picture in picture" inset on the
  Bevel Pair preview, `bevel_pair.bevel_pair_mesh_preview` +
  `BevelPreviewCanvas`'s `_MeshPreviewInset`) — the axial cross-section
  schematic this doc anticipates never shows an actual tooth (bevel
  flanks have no flat 2D profile), so a separate close-up was added,
  built from Tredgold's own flat back-cone-developed "virtual" spur gear
  substitution, reusing `gear_math.tooth_profile_points`.

## Scope

Scoped as a **pair specifically (exactly 2 members), not a generalized
N-stage bevel chain** — deliberately narrower than `GearChainFeature`.
Bevel trains longer than two gears are a rarer, more exotic case than
planar chains, and routing a 3D path through multiple arbitrary shaft
angles would import all of `GearChainFeature`'s bent-path/interference-
check complexity into a second, geometrically unrelated (intersecting-
axis, not parallel/coplanar) case. If a longer bevel train is wanted
later, it's an additive extension of this Feature type, not a redesign.

Mirrors `GearChainFeature`/`PlanetaryGearFeature`'s own live, re-
derivable pattern (one Feature, resolved fresh into multiple Bodies on
every recompute) — editing one gear's tooth count live-recomputes both
members' pitch cone angles and repositions/resizes automatically.

**Shared pair-level fields** (both gears physically share one axial
band/mesh, so these can't legitimately differ between the two members):
module, pressure angle, shaft angle, backlash, face width. **Flat fields
on the Feature itself, not a `GearGroup` reference** — deliberately
simpler than `GearChainFeature`'s group indirection, since a pair always
has exactly two members that always mesh each other; there's no third
station for a module change to happen at.

**Per-member fields**: tooth count, profile shift (legitimately differs
per member — used to balance strength between a small pinion and a large
gear).

**Shaft angle**: user-specified, arbitrary (not restricted to 90°),
feeding directly into `10-bevel-gear.md`'s cone-angle formula. **Default
90°**, pre-filled and editable — same "sensible default, always visible,
overridable" pattern used for the plane-anchor default
(`00-conventions.md`); 90° covers the overwhelming majority of real
bevel-gear use (right-angle drives, miter gears).

**Position**: apex-aligned — both gears' cone apexes coincide at one
point, axes intersecting at the specified shaft angle, anchored via
`plane_ref: PlaneRef` for the apex/primary-axis orientation (see
`00-conventions.md`).

**Interference checking (corrected — see status note above):** the
original reasoning below is still correct as far as it goes, but is not
the whole picture any more.

*Original text, still true*: with exactly two members that are always
the intended meshing pair, there's no "non-adjacent stage" case for
`GearChainFeature`'s own interference machinery (bent multi-stage paths,
non-meshing members that might still collide) to apply to.

*What's real today, not anticipated by that reasoning*: the two members
that *do* mesh can still have real, measurable tooth-tip interference at
the mesh line — an on-device finding (real `BRepAlgoAPI_Common` overlap
on a real pair, e.g. this app's own default 20T/40T pair at its default
20° pressure angle). `bevel_math.py` has a pure-math (no OCCT) predictive
proxy for this, calibrated against real overlap measurements:
`bevel_pair_mesh_margin_degrees`/`worst_bevel_pair_mesh_margin_degrees`
(how much angular clearance exists between one member's tooth tip and the
other's involute-flank floor), `bevel_pair_mesh_interference_warning`
(the non-blocking warning banner, suggesting a higher pressure angle),
and `minimum_intruder_profile_shift_for_mesh_clearance`/`maximum_
receiver_profile_shift_for_mesh_clearance` (bisection searches for a
profile-shift fix). `bevel_pair.resolve_member_profile_shifts` uses these
to auto-resolve each member's `profile_shift` (a `float | None` field,
`None` meaning "auto" — same sentinel convention as `RackFeature.
backing_height`, "explicit always wins"): if the pair would interfere, the
intruding member's shift is reduced and the receiving member's is grown
by the same amount (backlash-neutral at the pitch line, a real
mathematical identity, not an approximation — provided growing the
receiver doesn't itself flip it into being the new intruder in the
opposite direction, which the receiver's own step is capped against). The
client's `BevelDesignScreen` exposes this as an Auto/Manual toggle per
member next to the Profile shift field.

**Kept fully separate from `GearChainFeature`** — no bevel stage kind
added to the planar chain. A chain that needs to turn a 3D corner places
a `BevelPairFeature` alongside a `GearChainFeature`, rather than the
chain's bent-path/interference machinery (built around one shared plane)
being extended to a structurally different intersecting-axis case.

**Resolved since this doc was written** (see `docs/dxf-io/00-conventions.
md`'s "Bevel flat-pattern DXF" note, not the "likely resolution" text
originally here): bevel flat-pattern DXF export is **dropped from scope
entirely, not deferred** — a bevel tooth's flank is a curved 3D surface,
so there's no flat face to select at all under this app's Export Face
model. A cone flat-pattern development ("unroll the cone" transform)
would be a wholly separate, unrelated feature if ever wanted later,
sharing nothing with Export Face.

## Entry-screen note

The Gear Design screen (`08-entry-screen-and-preview.md`) exposes both
"Bevel Gear" (single, standalone, `10-bevel-gear.md`) and "Bevel Pair"
(this workstream) as separate type-selector options — mirrors how planar
gears expose both single External/Internal types and the Pair/Chain/
Planetary system options.

## Complexity/risk

*(Original scoping-time assessment, kept for context — see the status
note at the top of this doc for what's actually shipped.)* High — real
new positioning/validation logic (simpler than `GearChainFeature`'s own
in some ways, since a pair never needs its non-adjacent-stage collision
checking, but built on `10-bevel-gear.md`'s then-still-unproven
construction approach) plus the DXF flat-pattern question above, then
itself unspiked. Both landed: `10-bevel-gear.md`'s construction approach
shipped (with the flank-curve change described in its own status note),
and the DXF flat-pattern question resolved to "out of scope" per the
corrected section above — this workstream did turn out to need the real,
substantial pairwise interference/profile-shift system described above,
which this original assessment didn't anticipate.
