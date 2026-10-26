# OCCT 8.0.1 upgrade: second evaluation (2026-10-26)

Should the backend move from `pythonocc-core` 7.9.3 (OCCT 7.9.3) to the latest release, `pythonocc-core` 8.0.1.2 (OCCT 8.0.1)?
The first attempt (2026-09-26, branch `claude/occt-version-bump-a518x2`, since deleted) held the bump over an "accuracy
regression in OCCT's `GeomLProp_SLProps.Normal()`". This pass re-checks that finding, checks our own code, measures
both kernels on the same machine, and reads the release notes and the community reports for what we could use.

**Recommendation: upgrade.** The September blocker was a bug in our code, not in OCCT; it is fixed on this branch.
With it fixed, both kernels pass the whole suite and build the same geometry for every body the suite makes; 8.0.1 is
faster on the work this app does most and smaller to install. The real risks are binding behaviour changes (one of
which caused the September failure) and a young 8.x line; both are manageable and listed below. The comparison also
turned up two bugs of ours that exist on 7.9.3 today (1b fixed, 1c and 1e open).

## How this was tested

Two conda environments on one 4-core x86_64 sandbox, identical apart from `occt`/`pythonocc-core` (checked with
`micromamba list`): `environment.yml` as committed (7.9.3) and the same file with `pythonocc-core=8.0.1.2=novtk*`.
The arm64 (Pi 5) environment for 8.0.1.2 resolves (`micromamba create --dry-run --platform linux-aarch64`), and CI on
this branch runs the suite on native arm64. Nothing here was run on the Pi itself.

## 1. Our own correctness

### 1a. The September "OCCT regression" was ours (fixed)

`bevel._flank_fold_warning` sampled the flank surface and kept `props.Normal()` for each grid point while replacing
`props` on the next sample. In `pythonocc-core` 7.9.3 `Normal()` returned a copy. In 8.0 the SLProps classes became
SWIG `%template` instantiations of OCCT's new template class, and `Normal()` (and `D1U()`, `D1V()` …) now return a
*view* into the props object (`thisown == False`). Once the props object is freed the stored normal reads freed memory:

- against 8.0.1.2, 585 of 625 stored normals did not match a fresh evaluation at their own (u, v): most held another
  grid point's (unit-length) normal, a few held garbage (lengths 0 and 290 were seen);
- that is exactly the September symptom: non-unit "directions" of length ~41 and ~77, failures that depended on what
  else had run in the process, and no repro in a fresh script;
- 7.9.3 never showed it because the getter copied.

So the earlier conclusions need correcting:

| September claim | Now |
|---|---|
| `GeomLProp_SLProps.Normal()` in OCCT 8.0.1 returns wrong, non-unit values | No: the value is right while the props object lives; we read it after it was freed. |
| A stateful "stale lazy value" bug like the curvature one in pythonocc-core PR #1495 | Different bug. That one is real (see Drawbacks in 3), ours was a lifetime bug. |
| File it upstream against OCCT | The draft would have been wrong. (It was not filed: pythonocc-core has no such issue.) A *binding* report is still worth filing: 8.0.1.2 (#1501, "objects returned by reference keep their owner alive") does not cover the `%template` SLProps getters; the repro in the appendix still fails on 8.0.1.2. |
| ThruSections (`ruled=False`) uses the "experimental" 8.0.0 Gordon code | No: `libTKOffset` (which holds `BRepOffsetAPI_ThruSections`/`BRepFill`) has no Gordon symbols at all; Gordon is a separate `GeomFill` builder we do not call. |
| The September `D1U × D1V` fix | Right in effect, but only because it was computed while `props` was alive; `D1U()`/`D1V()` are views too. |

Fix: `bevel._flank_surface_grid` copies every point and normal; `test_fold_check_grid_normals_are_copies_not_views_into_freed_props`
fails without the copy on 8.0.1.2 (the same check caught it in 10 of 10 trials) and passes on both kernels with it.

Audit of the rest of the code for the same pattern: 38 const-reference getters on classes we import were probed on
both bindings (`thisown` of the result). Only the SLProps family changed to views. Two getters were views on 7.9.3
already, `TopoDS_Shape.Location()` and `Quantity_ColorRGBA.GetRGB()`; we never keep either past its owner. 8.0 made
container accessors (`FindFromIndex` and friends) copies, which removes a hazard that existed on 7.9.3. The probe list
is not exhaustive; the geometry comparison in 2 is the backstop.

### 1b. Open chains were walked in a random direction (fixed, affects 7.9.3 today)

Found by the geometry comparison: one open swept surface flipped orientation between kernels, and it flipped on the
*same* kernel between runs too. `detect_open_chain` picked the chain's start from a `set` of random uuid strings, so
the same sketch was walked either way from run to run. The direction decides which side a thin Loft's wall is on and
which way a swept, extruded or revolved surface faces. Measured on 7.9.3 before the fix: a 10 × 8 thin loft put its
1 mm wall on +Y in some runs and −Y in others; a two-segment one changed volume between runs (95.20 / 88.44 mm³).
Server restarts and reloads could therefore change a saved model. Now the walk starts at the end on the earliest-drawn
entity; `test_an_open_chain_is_always_walked_from_the_end_drawn_first` fails on the old code.

### 1c. Open: thin Loft through a multi-segment open chain

Same on both kernels, not fixed here. Two identical L-shaped open chains (10 mm and 6 mm legs) 8 mm apart, thickness 1:
every cross-section is the right L-shaped 1 mm wall (which implies ~136 mm³), point sampling gives ~117 mm³, GProp gives
88.44 mm³, the response carries the "mid-height cross-section is degenerate" warning, and `BRepCheck_Analyzer` calls
the solid valid. Something in the thickened solid is malformed; worth its own investigation.

### 1d. Seen once: a bevel pair job that would not cancel

One full 7.9.3 run had `test_cancel_during_an_active_phase_search_pool_kills_workers_and_never_persists` time out with
the job still `running` 60 s after cancel (four later tests in the file then got 409 "already running"). Two earlier full
runs and six repeat runs of the file (three per kernel, all 9 passed) did not reproduce it. Not kernel related;
noted because it is the same class as PRs #181/#214.

### 1e. Open: bodies the suite builds that `BRepCheck_Analyzer` rejects

Same 9 on both kernels, so not an upgrade issue, but the tests that build them pass:

| Test | Feature | Note |
|---|---|---|
| `test_sweep_along_an_arc_guide_drawn_in_either_direction_still_produces_a_body` | Sweep | 4 bodies; one has volume −15.1 (inside out) |
| `test_sweep_ellipse_fillet_chamfer_copy_merge_preserves_both_bodies_volume` | Merge of swept tubes | |
| `test_two_raw_swept_ellipse_stadium_tubes_merge_correctly` | Merge of swept tubes | |
| `test_spiral_bevel_pair_via_router_produces_a_valid_body_with_spiral_fields_in_the_response` | Spiral bevel pair | the test's name says valid |
| `test_low_tooth_count_gear_defaults_to_auto_and_clears_the_undercut_warning` | Gear | |
| `test_importing_an_stl_file_creates_a_new_body` | STL import | a mesh, no solid: expected |

Invalid solids can fail later Booleans, exports or printing. The negative-volume sweep looks like the same family as
1b (a path drawn the other way); not investigated.

## 2. Accuracy: every body the suite builds, on both kernels

A pytest plugin wrapped `extrude._apply_feature_to_bodies` and recorded, after every feature step, each body's volume,
area, centroid, solid/face/edge/vertex counts and `BRepCheck_Analyzer` validity, keyed by test, step and body.

- 9,005 bodies from 1,162 tests compared, none missing on either side.
- Topology counts identical for every body. Validity identical: 8,996 valid, and the same 9 invalid on both (see 1e).
- Volume, area and centroid identical to floating-point noise: worst relative volume difference 2.7e-15, worst
  centroid shift 1.4e-14 mm. The single exception was the open swept surface in 1b (an open shell's signed "volume"
  flipped sign), which turned out to be our nondeterminism, not the kernel.
- Spiral bevel pairs, whose meshing-phase search is the most numerically sensitive code we have, come out the same
  (same volumes, so the same phase was chosen).

So for what this app builds, 8.0.1 is not less accurate than 7.9.3: it gives the same answers.

## 3. Benefits and drawbacks, measured

### Speed

Whole suite (4 workers, same machine, run back to back): 7.9.3 took 759 s and 678 s in two runs, 8.0.1.2 took 609 s
with both fixes, so 10–20% faster. Do not compare against the 441 s seen before the fix: there the false fold
warning made spiral bevel pairs skip their meshing-phase search, which is most of their cost. (The September spike's speed impressions had the
same problem.)

Kernel micro-benchmarks (best of two rounds, each the median of three; `tools/occt_compare/kernel_bench.py`):

| Operation | 7.9.3 | 8.0.1 | 8.0 / 7.9 |
|---|---|---|---|
| Cut 400 holes from a plate (one Boolean) | 0.787 s | 0.684 s | 0.87 |
| `BRepCheck_Analyzer` on the 400-hole plate | 0.426 s | 0.240 s | 0.56 |
| `BRepCheck_Analyzer` on a 1,600-hole plate | 6.68 s | 2.60 s | 0.39 |
| 30 chained fuses | 0.360 s | 0.354 s | 0.98 |
| Fillet every edge of a holed block | 14.3 ms | 11.0 ms | 0.77 |
| Fine mesh of a torus (`BRepMesh`, 0.005 mm) | 2.31 s | 2.13 s | 0.92 |
| STEP write, 400-hole plate | 0.437 s | 0.302 s | 0.69 |

Volumes of the Boolean and fillet results are identical across kernels. The many-hole face check is the 8.0.1 release
note's "face validation with many disjoint holes" item and shows up as claimed; we run `BRepCheck_Analyzer` in seven
modules, so patterned holes and perforated plates benefit most.

App-level (real HTTP API, median of three, best of two rounds):

| Case | create 7.9 / 8.0 | `GET /mesh` 7.9 / 8.0 | STEP export 7.9 / 8.0 | STEP bytes 7.9 / 8.0 |
|---|---|---|---|---|
| Spur 20T m2 | 0.02 / 0.01 s | 0.14 / 0.13 s | 0.068 / 0.062 s | 529,707 / 529,707 |
| Helical 30°, 20T | 0.05 / 0.04 s | 0.14 / 0.16 s | 0.069 / 0.061 s | 586,268 / 586,236 |
| Herringbone 25°, 24T | 5.86 / 4.89 s | 6.35 / 4.95 s | 0.111 / 0.113 s | 1,153,372 / 1,153,374 |
| Internal ring 60T | 0.04 / 0.03 s | 0.41 / 0.36 s | 0.185 / 0.201 s | 1,626,517 / 1,626,517 |
| Planetary 20/60 × 5 | 1.05 / 0.98 s | 2.18 / 2.05 s | 0.553 / 0.614 s | 4,926,785 / 4,926,785 |
| Bevel pair 20/40, straight | 4.98 / 4.61 s | 5.54 / 4.56 s | 0.197 / 0.179 s | 2,094,435 / 2,094,435 |
| Spiral bevel pair 10/20, 20° | 5.61 / 5.13 s | 5.72 / 4.95 s | 0.162 / 0.164 s | 1,893,736 / 1,893,736 |

No case produced a warning on either kernel. The heavy builds (herringbone, bevel pairs) are 7–22% faster; the
light ones are within run-to-run noise. Mesh vertex counts are identical. (`tools/occt_compare/app_bench.py`.)

### Size and memory

- Install: 982 MB → 885 MB for the whole conda env (−10%), almost all of it the Python bindings (447 → 345 MB). The
  Docker image should shrink by about the same (not built here).
- Peak RSS of the app-benchmark process (app imported, all seven cases built): 607–622 MB → 555–559 MB (−9%).
  That matters most on the 4 GB Pi.
- `import app.main`: 2.4–2.6 s → 1.9–2.2 s (server start).

### STEP output

The OCCT 8.0.0 note "duplicate-entity removal reduces STEP files by about 20%" did not show up for us: the same model
wrote the same byte count on both kernels (1,584,232 bytes for the plate; the app's own exports in the table above
differ by at most 32 bytes). Writes are faster, files are not smaller.

### Threads

OCCT 8 makes fillets, STEP readers/writers and the error-handler stack thread-safe, but pythonocc holds the GIL during
kernel calls on both versions (two threads running Booleans: 0.68× and 0.83× the speed of serial, measured on a busy
machine, so indicative only). The process pools stay;
`BRepMesh_IncrementalMesh` already runs its own internal parallel mode (`mesh.py`).

### Drawbacks and risks

- **Binding behaviour changes.** Besides the SLProps views: pythonocc-core 8.0 dropped `Handle_*` helpers, made
  `DownCast` raise `TypeError`, `FindAttribute` return `None`, `TDocStd_Application.Open` return `[status, doc]`,
  removed `NCollection_Array1.next`, and changed several `OCC.Extend` helpers. We use none of these (checked by
  search); the suite passes. New code should copy anything it keeps from a getter (`gp_Dir(v.X(), v.Y(), v.Z())`).
- **Known upstream defect:** the curvature getters of the new SLProps template return 0.0 unless
  `IsCurvatureDefined()` is called first (pythonocc-core PR #1495, xfailed there). We do not use curvature today; any
  future use must call `IsCurvatureDefined()` first.
- **A young line.** 8.0.1 (30 Jul 2026) is the only maintenance release so far; 8.1 is expected to change the API
  again (build123d pins `<8.1` for that reason). We would pin exactly, as now.
- **Other projects' 8.0.1 regressions**, none of which touch an API we use: FreeCAD's TechDraw indexed a
  `TColgp_Array1OfPnt` at 0 (fixed with `.At()`), build123d needed smoothing degree 6 instead of 5 for C2
  ("WorkDegree too small" is now an error), and OCP (not pythonocc) dropped `BRepTopAdaptor_FClass2d`.

## 4. Using the advancements

What OCCT 8.0/8.0.1 add that this app could use, most useful first. None is needed for the upgrade itself.

1. **Loft guide curves that shape the section.** `loft.py` says guide curves only translate a section rigidly and that
   "a reshape … to hug the guide curve" is out of scope. OCCT 8's `GeomFill_Gordon` (rebuilt in 8.0.0p1, improved in
   8.0.1, wrapped in pythonocc 8 as `GeomFill`) builds a surface through a network of section and guide curves: the
   standard way CAD tools do guided lofts. It reports status and has an explicit approximate fallback. Biggest gain,
   needs a design pass and its own tests.
2. **Helices.** `curve.py` builds a helix as a 2D line on a cylinder plus `breplib.BuildCurves3d`, which approximates
   the 3D curve. OCCT 8 adds `TKHelix` (`HelixGeom`, `HelixBRep` in pythonocc: helices, including tapered ones) and an
   exact helix curve in `GeomEval`. Tapered threads and conical springs become possible; sweeps along a helix may get
   cleaner.
3. **Many-hole parts and STEP export get faster for free** (section 3). Nothing to write.
4. **`BRepGraph`** (157 classes wrapped): topology as a graph with durable `UID`s, history and layers. Relevant to the
   reference-identity work (`reference_signature.py`, `reference_history.py`) in the long run, but new, still being
   hardened, and a large API: watch, do not adopt yet.
5. **`GeomBndLib`**: tighter analytic bounding boxes. We call `brepbndlib.Add`, which pads B-spline boxes by their
   control polygon (seen above as ~1.4 mm of overshoot on a thin loft). Useful where a box drives a decision.
6. **Smaller wins in the bindings** (pythonocc-core's own figures, PR #1495): calls 12–15% faster, faster topology
   utilities, `OSD_ThreadPool` control from Python.

## 5. Upgrade steps

1. Merge the two fixes (they are correct on 7.9.3 too).
2. Pin `pythonocc-core=8.0.1.2=novtk*` in `backend/environment.yml` (the last commit on this branch); CI runs both
   architectures.
3. Rebuild the Pi image and spot-check bevel pairs, thin lofts and STEP export from the app.
4. File the binding report with pythonocc-core (draft in the appendix).

## Appendix: binding report draft for tpaviot/pythonocc-core

> **`GeomLProp_SLProps.Normal()` / `D1U()` / `D1V()` return a view into the props object; it dangles once the props object is collected (8.0.1.2)**
>
> In 7.9.3 these getters returned a copy (`thisown == True`). Since the classes became `%template` instantiations in
> 8.0.1 (#1495) they return a non-owning wrapper (`thisown == False`). #1501's "objects returned by reference keep
> their owner alive" does not seem to cover them. Keeping the result after the props object goes reads freed memory:
>
> ```python
> import math
> from OCC.Core.GeomAPI import GeomAPI_PointsToBSplineSurface
> from OCC.Core.GeomLProp import GeomLProp_SLProps
> from OCC.Core.TColgp import TColgp_Array2OfPnt
> from OCC.Core.gp import gp_Pnt
>
> poles = TColgp_Array2OfPnt(1, 6, 1, 6)
> for i in range(1, 7):
>     for j in range(1, 7):
>         poles.SetValue(i, j, gp_Pnt(i * 10.0, j * 10.0, 3 * math.sin(i) * math.cos(j)))
> surface = GeomAPI_PointsToBSplineSurface(poles).Surface()
> u1, u2, v1, v2 = surface.Bounds()
> kept, uvs = [], []
> for i in range(25):
>     for j in range(25):
>         u, v = u1 + (u2 - u1) * i / 24, v1 + (v2 - v1) * j / 24
>         props = GeomLProp_SLProps(surface, u, v, 1, 1e-6)
>         props.IsNormalDefined()
>         kept.append(props.Normal()); uvs.append((u, v))
> wrong = 0
> for n, (u, v) in zip(kept, uvs):
>     fresh = GeomLProp_SLProps(surface, u, v, 1, 1e-6); fresh.IsNormalDefined(); f = fresh.Normal()
>     wrong += abs(n.X() - f.X()) + abs(n.Y() - f.Y()) + abs(n.Z() - f.Z()) > 1e-9
> print(wrong, "of", len(kept), "kept normals are wrong")   # 7.9.3: 0 of 625. 8.0.1.2: 516-585 of 625.
> ```
>
> Seen in practice as non-unit `gp_Dir` values (lengths 0, ~41, ~77, ~290). Expected: a copy, or the owner kept alive,
> as for the container accessors. Linux x86_64, Python 3.11, conda-forge `pythonocc-core 8.0.1.2 novtk`.

## Sources

- OCCT releases: [8.0.1](https://github.com/Open-Cascade-SAS/OCCT/discussions/1415), [8.0.0p1](https://github.com/Open-Cascade-SAS/OCCT/releases/tag/V8_0_0_p1), [8.0.0](https://github.com/Open-Cascade-SAS/OCCT/releases/tag/V8_0_0)
- pythonocc-core: [PR #1495 (OCCT 8.0.1)](https://github.com/tpaviot/pythonocc-core/pull/1495), [releases](https://github.com/tpaviot/pythonocc-core/releases), [issue #1499](https://github.com/tpaviot/pythonocc-core/issues/1499)
- FreeCAD: [OCCT 8 tracking issue](https://github.com/FreeCAD/FreeCAD/issues/25496), [TechDraw 8.0.1 regression](https://github.com/FreeCAD/FreeCAD/pull/33256), [8.0.0 discussion](https://github.com/FreeCAD/FreeCAD/discussions/30016)
- build123d: [OCP 8 port, PR #1442](https://github.com/gumyr/build123d/pull/1442)
