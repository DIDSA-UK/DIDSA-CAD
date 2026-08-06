# Workstream 2 — `GearFeature`: external + internal spur gears

Read `00-conventions.md` first (positioning, curve representation, and
downstream-Feature-compatibility are all resolved there, not repeated
here). Depends on Workstream 1 (`gear_math.py`).

## Scope

New `Feature` subclass (six-part checklist, `00-conventions.md`).
Parameters: `plane_ref: PlaneRef` (see conventions), module (mm), tooth
count, pressure angle, face width (extrude depth), profile shift,
backlash, root fillet radius, and (internal only) rim/outer diameter.

New file `app/document/gear.py` (OCCT-dependent half): turns
`gear_math`'s sampled profile points into OCCT edges/wire, each tooth
flank a real `Geom_BSplineCurve` (see conventions), then extrudes via the
same `BRepPrimAPI_MakePrism` path `ExtrudeFeature` already uses.

**Internal gears**: build as one annulus profile (outer rim boundary +
inward-facing involute tooth boundary), one Boss — not a separate Cut
step.

## Complexity/risk

Medium-high for the OCCT curve/profile assembly (wire winding
direction/continuity around a full gear — 20+ repeated tooth profiles
stitched into one closed wire — is fiddly, similar to this codebase's own
experience with Slot/Polygon closed-form geometry). Low for Boss/Cut
integration (copy-paste from `ExtrudeFeature`'s existing pattern).
