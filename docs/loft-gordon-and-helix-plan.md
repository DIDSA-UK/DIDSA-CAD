# Plan: Gordon lofts and OCCT 8 helices (2026-10-26)

For an implementation session. Background and measurements: `docs/occt-8-upgrade-evaluation.md` (sections 1b, 1c and 4).
The backend runs OCCT 8.0.1 / pythonocc-core 8.0.1.2 since PR #308. Decisions below were made with the owner; do not
reopen them without asking.

## Decisions

| Topic | Decision |
|---|---|
| Where Gordon is used | **Every Loft and Loft Surface feature**, guided or not. Unguided lofts get hidden guides through corresponding section vertices. Out of scope: the internal `ThruSections` calls in `gear.py`, `bevel.py`, `bevel_math.py`, `body_cache.py`, `sketch/profile.py`, and `RuledSurfaceFeature`. |
| If the spike shows Gordon is worse for unguided lofts | Fall back: Gordon for guided lofts only, `ThruSections` stays for unguided ones. Record why in the spike write-up and carry on without waiting. |
| A guide that misses a section | Use Gordon's approximate mode (`SetApproximationMode(AllowApproximateFallback)`) and return a warning stating the deviation. If even that fails, a 422 naming the guide and the section. |
| Faces | **One face per section edge**, as now: a guided loft between rectangles has 4 side faces with real corner edges. |
| The old guide behaviour | **Replaced.** Guides always reshape the surface. Remove the rule that every section needs an `alignment_point` when guides are set, and the guide-driven translation in `_apply_alignment_point_translation`. `alignment_point` stays only for unguided "line the sections up" use. |
| Number of guides | Several per loft (that is the point of Gordon). |
| Helix builder | `HelixBRep_BuilderHelix` for **every** helix. Old files: no migration (pre-release). |
| Taper | Accept **either** an end radius or a taper angle; store one, return both. |
| Variable pitch | **Included**: a helix is a list of (pitch, turns) segments. |
| Clients | Flutter (loft panel, curve panel), DIDSA-VR (loft guide picking, a new Helix tool with taper and segments), AI plan (several guides). |
| Shipping | **One PR per repo.** Stop at each milestone below: run the full suites, then hand the owner a checklist to run on the device / headset, and continue when they say so. Merge each PR after the owner's go-ahead at the last milestone, DIDSA-CAD first (DIDSA-VR depends on its API). |

## Milestone 1: spike (backend, throwaway code)

Answer these with real OCCT before writing feature code; write the answers to `docs/loft-gordon-spike.md`. Spike code
does not ship. Use `tools/occt_compare/` (the `geomdiff` plugin) to compare constructions.

What already works from Python (checked 2026-10-26): `GeomFill_Gordon().Init(profiles, guides, tol)` with
`TColGeom_Array1OfCurve` inputs, `Perform()`, `IsDone()`, `Status()`, `IsApproximate()`, `Surface()`. Two straight
profiles and two bulging guides gave an exact surface through all four curves in 17 ms.

1. **One face per edge.** Two candidates; pick one:
   - (a) one Gordon surface over the whole network, with hidden guides at every section vertex, split into faces along
     those guides' isoparameter lines;
   - (b) one Gordon network per span between neighbouring vertex guides, the faces sewn (`BRepBuilderAPI_Sewing`).
   Check the shared edges are real, the solid is valid, and filleting a corner edge works.
2. **Closed sections.** A rectangle-to-rectangle and a circle-to-square loft (closed, periodic networks; 8.0.1 improved
   closed-network contact selection). Our sections are multi-edge wires; `_harmonize_section_wire_edge_counts` already
   makes the edge counts match.
3. **Hidden guides for unguided lofts.** A curve through each set of corresponding vertices (the correspondence the
   seam, reverse and auto-align machinery already produces). Interpolation type and end tangents.
4. **Ruled lofts.** Per-span construction with straight hidden guides. Must match today's `ThruSections(ruled=True)`.
   User guides with `ruled=True`: decide whether that is a 422 (likely; they contradict).
5. **Guides that miss.** Guides 0.2 mm off, 2 mm off and missing a section entirely. Does the approximate mode build
   something, how big is `ToleranceReached()`-style deviation, and is it reported? If approximate mode cannot handle a
   network that does not intersect, say so; the fallback is to snap crossings within a tolerance and warn, 422 beyond.
6. **A guide crossing mid-edge** (not at a vertex), and a guide that moves from one edge to the next between sections.
7. **End caps.** Planar caps from sketch sections; what to do for non-planar `edge_ref` sections (today `ThruSections`
   caps them).
8. **Thin lofts.** Open-chain and closed-profile thin lofts through `thicken_shell_to_solid`. Include the malformed
   L-chain case from `docs/occt-8-upgrade-evaluation.md` 1c: two L-shaped chains (10 mm and 6 mm legs) 8 mm apart,
   thickness 1, should give ~136 mm³ and a consistent solid.
9. **Unguided comparison.** Build every body from the loft tests (`tests/test_loft_*.py`, `test_ruled_surface*`,
   anything else building a `LoftFeature`/`LoftSurfaceFeature`) both ways. Gordon is "not worse" when: every loft test
   still passes, every body is valid where `ThruSections`' was, volume within 1%, the same face count, and no case more
   than 3x slower. Otherwise apply the fallback decision.
10. Coarse (LOD) previews (`resolve_loft_coarse_from_bodies`: first and last section only) still work with guides.

Stop: run the backend suite, commit the write-up. No owner checklist needed here; continue.

## Milestone 2: lofts on Gordon (backend, Flutter, AI plan)

**Model** (`backend/app/document/models.py`, `schemas.py`, `native_format.py`):

- `LoftFeature.guide_curve_refs: list[SketchOrEdgeRef]` (one chain) becomes `guide_curves: list[list[SketchOrEdgeRef]]`
  (each guide its own ordered chain, resolved with `sweep.resolve_path_wire` as now). Same on `LoftSurfaceFeature`.
  No migration of old files.
- Update the docstrings that describe the old translation-only guide (`LoftFeature`, `LoftSection.alignment_point`,
  the `loft.py` module docstring).

**Construction** (`backend/app/document/loft.py`, `loft_surface.py`):

- Gordon construction from the spike, used by the solid, thin-from-closed and open-thin paths and by Loft Surface.
- Keep section resolution, `reference_point` rotation, seam / reverse / auto-align, and edge-count harmonisation: they
  define the vertex correspondence the hidden guides go through.
- Map Gordon's `ResultStatus` values to clear 422 `loft_failed` / `invalid_guide_curve_ref` messages that name the
  guide and section. Approximate builds return a warning with the deviation.
- `_mid_section_warnings` stays.
- Router validation (`_validate_loft_guide_curve_refs` and friends): drop the alignment-point requirement; validate
  each guide chain; reject `ruled` with guides if the spike says so.

**Tests**: guided-loft accuracy (sample the surface along each guide: on it within tolerance for exact builds),
closed and open, mid-edge guides, misses (approximate plus warning; 422 when impossible), one face per edge (corner
edges exist and can be filleted), ruled, thin lofts including the L-chain case, coarse preview, native round trip.
Existing loft tests keep passing (adjust only ones that pinned the old translation behaviour, and say which).

**Flutter** (`client/lib/viewport3d/loft_panel.dart`, `loft_surface_panel.dart`, `part_screen.dart`,
`api/document_api_client.dart`): pick several guides (add, list, remove each), drop the "every section needs an
alignment point" flow, show approximate-build warnings. `flutter analyze` and `flutter test` (what `client-verify.yml`
runs).

**AI plan** (`backend/app/document/ai_plan.py`, `ai_plan_schemas.py`; `client/lib/ai/ai_plan.dart`,
`ai_plan_translator.dart`, `ai_scoping_prompt.dart`): `guide_curve_refs: list[str]` becomes a list of guides, each a
list of local ids; the prompt explains that guides shape the loft and should touch every section.

Stop: full backend suite, Flutter analyze and test. Owner checklist (on device): unguided loft between a square and a
circle; a guided loft with two guides bulging out; a guide that deliberately misses (expect a warning); a thin loft
from two L-shaped open chains; fillet a corner edge of a guided rectangle loft; an AI plan request that uses guides.

## Milestone 3: helices on HelixBRep (backend, Flutter)

**Model** (`CurveFeature`, schemas, native format; no migration):

- `radius` stays the start radius. New `end_radius: float | None` (None: constant radius).
- Requests may give `taper_angle_degrees` instead of `end_radius` (not both). The router converts it:
  `end_radius = radius + total_height * tan(taper)`, positive widening along the axis. Store `end_radius`; responses
  return both.
- `pitch` and `turns` are replaced by `segments: list[{pitch, turns}]` (at least one). Total height is the sum of
  pitch x turns.
- `right_handed` stays.

**Construction** (`backend/app/document/curve.py` `_resolve_helix_from_bodies`): `HelixBRep_BuilderHelix.
SetParameters(axis: gp_Ax3, diam_start, diam_end, pitches, turns)` (diameters, not radii), `Perform()`, check
`ErrorStatus()`, take the wire from `Shape()`. Spike first, in this milestone: left-handed helices (if the builder has
no hand option, mirror across the plane through the axis), start point and direction from the axis plane's x-axis
(must match today's start at angle 0), and a negative pitch. Consumers that must still work: Sweep along a helix
(`sweep.py` via `curve_feature_id`), Create Plane normal to a curve (`create_plane.py`,
`point_and_tangent_at_fraction`), Fill Surface curve refs (`fill_surface.py`).

**Tests** (`tests/test_curve_features.py` and new ones): constant helix matches the old one's start, end and length;
tapered by end radius and by angle give the same curve; segments give the right height and pitch per segment;
left-handed; sweep a circle along a tapered, variable-pitch helix to a valid solid with the expected volume
(`pi r^2 L`); create a plane at 0.5 along a tapered helix.

**Flutter** (`client/lib/viewport3d/curve_panel.dart`, `part_screen.dart`, `api/document_api_client.dart`): end radius
or taper angle (a toggle between them, the other shown read-only), a segments list (add / remove rows of pitch and
turns).

Stop: full backend suite, Flutter analyze and test. Owner checklist (on device): a tapered helix by end radius and by
angle; a spring with tight end coils (three segments); sweep a circle along each; a plane normal to a tapered helix.

## Milestone 4: DIDSA-VR (loft guides, Helix tool)

Read `DIDSA-VR/CLAUDE.md` first (tests that load `main.tscn` must point `secrets_file_path` at a missing file; new test
files go in `tests/run_all.sh`, `tests/README.md` and, for live-backend tests, `tests/e2e_ci_list.txt`).

- **Loft guides** (`scripts/design_table/features/loft_tool.gd`, `scripts/design_table/part_features.gd`): a "Guides"
  step that picks curves (sketch lines, body edges, curve features) into one or more guides, shows the count, clears.
  Build the request with `guide_curves`. Show approximate-build warnings.
- **Helix tool** (new `scripts/design_table/features/helix_tool.gd`, registered in `feature_tools.gd` and
  `table_tools.gd`, icon in `scripts/ui/ui_icons.gd`): axis from a picked plane or planar face, radius, end radius or
  taper angle, segments (pitch, turns; add / remove), hand. Preview, Apply, Edit from the Build tree, a summary line.
  `visibility.gd` already shows curve rows.
- Update `docs/backend-api-notes.md` for the changed loft and curve payloads.
- Tests: headless suite (`tests/ci.sh`), and an e2e test against a live backend from the CAD branch for a guided loft
  and a tapered helix.

Stop: VR headless and e2e suites. Owner checklist (headset): pick two guides for a loft and apply; make a tapered
spring with three segments; edit it from the Build tree.

Then, on the owner's go-ahead: merge the DIDSA-CAD PR, then the DIDSA-VR PR. Update `docs/status.md` in each repo.

## Out of scope (on the roadmap)

- Thread feature (`docs/roadmap.md`, uses these helices).
- `BRepGraph` spike for reference identity (`docs/roadmap.md`).
- The 9 bodies `BRepCheck_Analyzer` rejects (`docs/occt-8-upgrade-evaluation.md` 1e) unless a loft is among them.
