# Workstream 1 — Gear math core

Read `00-conventions.md` first. No dependencies on other workstreams —
this is the foundation everything else builds on.

## Scope

New file: `backend/app/document/gear_math.py`, pure Python, zero OCCT
import (see conventions: OCCT-free/dependent split).

- **Involute curve sampling**: `x = r_b(cos t + t sin t)`, `y = r_b(sin t
  − t cos t)` — base circle, addendum/dedendum circles, tooth spacing from
  module + tooth count, pressure angle, root fillet, profile
  shift/correction (needed at low tooth counts to avoid undercut),
  backlash allowance.
- **Rack tooth generation**: trapezoidal, straight-sided — genuinely
  different math from involute sampling, not a variant of it.
- **Pair/mesh validation**: center distance = `module * (N1 + N2) / 2`
  for an external-external pair, `module * (N_ring − N_sun) / 2` for a
  sun/ring pair.
- **Planetary assembly-condition validation**: `(N_sun + N_ring) mod
  N_planets == 0`, plus a minimum-planet-count/interference check.
  Planet tooth count itself is **not** a free input — see
  `05-gear-chain-and-planetary.md` for why it's computed as
  `N_planet = (N_ring − N_sun) / 2`, and provide that computation here.

Fail closed with a structured error for anything with no valid geometry
(e.g. a non-integer/non-positive planet tooth count) — see conventions'
validation-banner exception.

## Test requirement

Real reference-value test suite (known standard gear dimensions — e.g. a
module-2/20-tooth/20°-pressure-angle gear's known base circle diameter),
not just "it runs." Wrong formulas produce gears that don't mesh, not
just cosmetically wrong ones.

## Complexity/risk

Medium. Math is well-documented (AGMA/ISO 21771), but precision matters.
