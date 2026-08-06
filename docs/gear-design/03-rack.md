# Workstream 3 — Rack tooth-profile generator

Read `00-conventions.md` first. Depends on Workstream 2 (`GearFeature`
machinery) and Workstream 1 (`gear_math`'s rack generator).

## Scope

A standalone rack: same `GearFeature`-family Feature, but a linear
trapezoidal-tooth profile (from `gear_math`'s rack generator — genuinely
different math from involute sampling, straight-sided not curved) over a
specified length instead of a full disc, for a user who wants just a rack
on its own.

**Pairing a rack with a pinion is out of scope here** — that's
`05-gear-chain-and-planetary.md`, which owns all multi-gear positioning
(pairs, chains, rack-and-pinion, planetary) as one unified concept.

## Complexity/risk

Low-medium — mostly reuses Workstream 2's machinery.
