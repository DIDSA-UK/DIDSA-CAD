# DIDSA-CAD Status Summary — 2026-06-23 (Stage 11)

## What this covers

Stage 11 — Edge Rendering & Wireframe Toggle: real OCCT edge geometry from
the backend, and a three-mode viewport display toggle (Shaded / Shaded +
Edges / Wireframe) on the client. Plus a full audit of reference-plane,
sketch, and extrude coordinate mapping for size/position/scale bugs.

## Backend

- `backend/app/document/mesh.py`:
  - `MeshData.edges: list[float]` — a new flat `[x1,y1,z1, x2,y2,z2, ...]`
    field alongside the existing `vertices`/`normals`/`triangles`.
  - `_extract_edges(shape)` walks every unique edge in the shape via
    `TopTools_IndexedMapOfShape` + `TopExp.MapShapes(shape, TopAbs_EDGE, ...)`
    (not a plain `TopExp_Explorer`, which would double-visit edges shared
    between two faces), skips degenerate edges (`BRep_Tool.Degenerated`),
    and samples each surviving edge's *real curve* via `_sample_edge`.
  - `_sample_edge(edge)` uses `BRepAdaptor_Curve` +
    `GCPnts_TangentialDeflection` (the same algorithm OCCT's own viewer uses
    to discretize curves for display) to produce 2 points for a straight
    edge or more for a curved one, each chord within
    `EDGE_CHORD_HEIGHT_TOLERANCE = 0.1` of the true curve.
  - `tessellate_shape()` now also sets `mesh.edges = _extract_edges(shape)`.
  - Edges are sampled straight from OCCT topology/geometry, deliberately
    independent of the triangle mesh's own tessellation — so a box always
    reports exactly 12 clean edge segments regardless of how finely its
    faces happen to be triangulated, rather than leaking every tessellation
    triangle's edges into the wireframe.
- `backend/app/document/schemas.py`: `MeshVertexData.edges: list[float]`,
  a required field (no default) — every mesh response now must include it.
- `backend/app/document/router.py`: `_mesh_vertex_data()` passes through
  `mesh_data.edges`; the empty-solid (no Extrude Features yet) branch
  constructs `MeshVertexData(..., edges=[])` so the placeholder mesh keeps
  responding with a valid (empty) `edges` array rather than omitting the
  field.
- New tests in `backend/tests/test_stage11_edges.py`:
  - `test_box_extrude_mesh_includes_a_non_empty_edges_field`
  - `test_box_extrude_returns_exactly_12_edges` — a box has exactly 12
    edges; this would catch any double-counting from a plain explorer.
  - `test_edge_endpoints_are_consistent_with_mesh_vertex_positions` — every
    sampled edge endpoint must lie at (or extremely near) one of the mesh's
    own triangle vertices, catching any coordinate-system mismatch between
    the two code paths.
  - `test_placeholder_mesh_also_includes_edges`
  - `test_empty_computed_mesh_has_empty_edges`

### Geometry audit (reference planes / sketch / extrude coordinate mapping)

Reviewed `backend/app/document/extrude.py`, `router.py`'s plane/sketch
endpoints, and `mesh.py` end-to-end for the sketch-plane → 3D-world mapping
the brief asked to audit. **No bugs found.** Specifically checked:

- `extrude.py`'s `BRepBuilderAPI_Transform(face, start_transform, True)` —
  the trailing `True` is OCCT's "copy geometry" flag, meaning the
  transformed face's vertices/edges are baked into new absolute-coordinate
  geometry rather than carried as a `TopLoc_Location` wrapper on the
  original. This matters for Stage 11 specifically: `_sample_edge` reads
  edge curves directly with no location/transform applied, so if any shape
  in the pipeline carried a non-identity `TopLoc_Location` instead of baked
  geometry, sampled edges would silently report the wrong (untransformed)
  coordinates while the triangle mesh (which *does* apply
  `location.Transformation()` in `_append_face_triangles`) reported the
  right ones. Confirmed this can't happen here: every shape reaching
  `tessellate_shape` is built via copy-transforms, so this divergence is
  not live. Documenting it because it's the one place a future change
  (e.g. swapping in a `BRepBuilderAPI_Transform(..., False)` for
  performance) would reintroduce it without `_sample_edge` itself ever
  changing.
- Reference-plane sizing/placement and sketch-to-3D coordinate mapping
  (the other half of the audit) were already covered by the Stage 10a/10b
  sessions' own reviews and remain unchanged by Stage 11 — no new backend
  code touches that mapping, only mesh tessellation/edge extraction.

## Client

- `client/lib/viewport3d/render_mode.dart` (new): `ViewportRenderMode` enum
  (`shaded` / `shadedWithEdges` / `wireframe`) plus an extension supplying
  each mode's label, icon, `showsFilledFaces`/`showsEdges` flags, and edge
  color (`#333333` for shaded+edges, `#666666` for wireframe, transparent/
  unused for shaded).
- `client/lib/viewport3d/mesh_geometry.dart`: added
  `edgeSegmentsFromMesh(MeshDto)` (groups the flat `edges` array into
  `(Vector3, Vector3)` segment pairs), `nudgeSegmentsOutward(segments,
  center, amount)` (pushes each endpoint away from a center point — the
  z-fighting mitigation for shaded+edges mode, since this version of
  `flutter_scene` (0.18.1) has no native GPU depth-bias API), and
  `buildMeshEdgesNode(segments, {color, width})` (one `PolylineGeometry`
  primitive per segment, `UnlitMaterial`, opaque).
- `client/lib/api/document_api_client.dart`: `MeshDto` gained an `edges:
  List<double>` field, defaulting to `const []` and parsed defensively
  (`json['edges'] as List?`) so existing test fixtures that predate Stage
  11 and omit the key entirely keep working unmodified.
- `client/lib/viewport3d/part_viewport.dart`:
  - New `renderMode` prop (default `ViewportRenderMode.shaded`).
  - New `_edgesNode` + `_syncEdgesNode()`, mirroring the existing
    `_syncMeshNode`/`_meshNode` pattern: removes any existing edges node,
    then (if the mode shows edges and the mesh has any) rebuilds one from
    `edgeSegmentsFromMesh`, nudging outward via `nudgeSegmentsOutward` only
    in `shadedWithEdges` mode (wireframe has no co-planar filled faces to
    fight against, so it skips the nudge).
  - `_syncMeshNode()` now skips building the filled-face node entirely when
    `renderMode.showsFilledFaces` is false (wireframe), but still runs the
    camera bounds/target/zoom logic unconditionally afterward — so toggling
    modes never moves the camera.
  - `didUpdateWidget` re-syncs both nodes when `renderMode` changes.
  - `_ScenePainter`'s `polylineCarryingNodes` list now includes `_edgesNode`
    (alongside the pre-existing plane/sketch nodes) so its per-frame
    `updateForCamera()` call reaches the new edges too.
- `client/lib/viewport3d/part_toolbar.dart`: new `renderMode` +
  `onRenderModeChanged` props; renders one `ListTile` per
  `ViewportRenderMode` value (three discrete tappable entries, not a single
  cycling toggle — three states don't fit the "label names the next state"
  convention the Hide/Show Reference Planes entry above it uses), with a
  check-mark `trailing` icon on whichever mode is currently active.
- `client/lib/viewport3d/part_screen.dart`: new `_renderMode` state
  (default `shaded`) and `_onRenderModeChanged` handler, wired into both
  `PartViewport` and `PartToolbar` — the same controlled-widget pattern
  already used for `_referencePlanesHidden`.
- Sketch lines (`sketch_geometry_3d.dart`) were reviewed and need no
  change: they already render independently of render mode (always drawn,
  same color/width regardless of shaded/wireframe), which already
  satisfies the brief's "render consistently with edge lines in both
  modes" requirement.

### New/updated tests

- `client/test/mesh_geometry_test.dart`: four new tests —
  `edgeSegmentsFromMesh` groups a flat array into segment pairs and returns
  none for an empty array; `nudgeSegmentsOutward` pushes a point away from
  center by the given amount and leaves a point exactly at center
  unchanged.
- `client/test/part_screen_test.dart`: one new widget test verifying the
  toolbar's three render-mode entries appear, set
  `PartViewport.renderMode` correctly across taps (shaded → wireframe →
  shaded+edges), and mark the active entry with a check — using the
  pre-existing `_FakeDocumentBackend` whose placeholder mesh fixture
  deliberately still omits the `edges` key, exercising the new
  `MeshDto.fromJson` defensive default directly.

## Known limitations this session

**Backend (OCCT) code was never executed against a real `pythonocc-core`
binding.** `pythonocc-core` has no PyPI wheel, so it normally needs a
conda/mamba environment; this sandbox has no conda pre-installed but does
have network + disk, so a Miniforge3 distribution was installed fresh and
`mamba env create -n didsa -f environment.yml` was attempted. It failed
repeatedly with a TLS certificate error on every conda-forge/prefix.dev
channel download:

```
Download error (60) SSL peer certificate or SSH remote key was not OK
SSL certificate OpenSSL verify result: self-signed certificate in certificate chain (19)
```

`openssl s_client -connect conda.anaconda.org:443` confirms the sandbox's
outbound network is intercepted by an Anthropic-issued egress-gateway proxy
certificate (`issuer=O = Anthropic, CN = Egress Gateway SDS Issuing CA
(production)`), which `pip`/`curl`-via-Python already trust (via
`SSL_CERT_FILE`/`REQUESTS_CA_BUNDLE`, pre-set in this environment) but
libmamba's own bundled CA store does not. Explicitly exporting
`CONDA_SSL_VERIFY`, `CURL_CA_BUNDLE`, and `SSL_CERT_FILE` to the system CA
bundle (`/etc/ssl/certs/ca-certificates.crt`) before retrying did not
change the outcome — the failure persisted identically. Per this
environment's own time-boxing, further conda/SSL troubleshooting was
abandoned in favor of the items the brief actually asks for.

What *was* verified in this sandbox:
- `backend/app/document/mesh.py`, `schemas.py`, `router.py`, and
  `test_stage11_edges.py` all pass `python3 -m py_compile` (syntactically
  valid).
- `fastapi`/`pydantic`/`httpx`/`pytest` were installed directly via `pip`
  against the system Python (separate from the sandbox's `uv`-managed
  `pytest` binary, which runs its own bundled Python and can't see
  `pip`-installed packages — `python3 -m pytest` must be used instead).
  With these installed, `python3 -m pytest tests/test_stage2_profile.py
  tests/test_stage2a_solver.py` passes 10/10 (the only two test files with
  no `OCC` import at module scope), confirming the rest of the Python
  toolchain is sound and the failure is isolated to the missing OCCT
  binding.
- Every other backend test file (including all pre-existing Stage 0–9
  suites, not just the new Stage 11 one) fails to even *collect* with
  `ModuleNotFoundError: No module named 'OCC'`, since `app/main.py` imports
  OCCT at module scope — this is a pre-existing sandbox limitation, not
  something Stage 11 introduced.
- Manual code review of `_extract_edges`/`_sample_edge` against the OCCT
  API (`BRep_Tool.Degenerated`, `BRepAdaptor_Curve`,
  `GCPnts_TangentialDeflection`, `TopTools_IndexedMapOfShape` +
  `TopExp.MapShapes`) and a coordinate-system audit (see above) found no
  issues, but this is review, not execution.

**No Flutter/Dart SDK is available in this sandbox either** (re-verified:
`which flutter dart` empty, filesystem-wide `find` for a `flutter` binary
empty) — same limitation every prior session in this environment has
hit. None of the client changes above have been run through `flutter
analyze` or `flutter test`. All edits were made by reading each full file
before and after editing, cross-checking call sites, and manually
verifying brace balance and import correctness across every changed file.

**This means none of the new backend or client tests in this stage have
actually been executed end-to-end** — they were written to match each
suite's established patterns and reasoned through manually. A real
`pytest`-with-OCCT run and a real `flutter test` run are both needed before
fully trusting them.

## Branch / merge state

All Stage 11 work is committed on `claude/new-session-53c5v5` (the branch
this session was directed to use, overriding the brief's suggested
`stage-11-edge-rendering` branch name) and pushed to `origin`. A PR from
`claude/new-session-53c5v5` into `main` is being opened as part of this
session. **It is not to be merged** — left open for human review, per
standing project rules.

## What's next

- Get a working `pythonocc-core` binding (a real conda/mamba install
  outside this sandbox's network-egress restrictions, or a container with
  the OCCT bindings pre-baked) and run the full backend suite for real,
  especially `test_stage11_edges.py` against actual OCCT topology — this is
  the highest-value unverified piece, since `_extract_edges`/`_sample_edge`
  have never executed.
- Run `flutter analyze` and `flutter test` on a machine with the Flutter
  SDK to confirm the new render-mode/edge-rendering client code actually
  compiles and the new tests pass.
- Visually confirm on-device: that Shaded+Edges' outward-nudge actually
  eliminates z-fighting at the box's actual scale (no SDK was available to
  render anything in this sandbox, so `meshEdgeNudgeAmount = 0.02` is an
  untested initial guess, not a tuned value), and that Wireframe mode's
  filled-face suppression doesn't leave a flickering/empty viewport when a
  Part has zero edges (e.g. mid-rebuild).
- Review the open PR and merge if it looks good — it was deliberately left
  unmerged.
