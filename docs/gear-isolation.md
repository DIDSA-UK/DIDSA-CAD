# Gear isolation (groundwork for splitting gears out)

Goal: make the gear family (spur gear, rack, bevel gear, bevel pair, gear chain, planetary gear, `/gear/preview`) a
self-contained slice so it can be tested, iterated on - and later, if wanted, packaged - without touching the rest of the CAD.
This file is the map of what is already isolated and what still reaches into shared code.

## Backend: what lives where

| Layer | Gear-only files | Shared files with gear touchpoints |
|---|---|---|
| Maths (no OCCT) | `gear_math.py`, `gear_chain_math.py`, `bevel_math.py` | - |
| Geometry (OCCT) | `gear.py`, `rack.py`, `gear_chain.py`, `bevel.py`, `bevel_pair.py`, `planetary_gear.py` | - |
| Background jobs | (bevel pair / planetary entries) | `jobs.py` |
| **HTTP routes** | **`gears_routes.py`** (new: create / update / coarse preview / jobs / `/gear/preview`) | `router.py` includes it as its last statement |
| Feature dataclasses | `GearFeature`, `RackFeature`, `BevelGearFeature`, `BevelPairFeature`, `GearChainFeature`, `PlanetaryGearFeature` (+ enums, member/stage/group specs) | `models.py` |
| Request/response schemas | `Gear*`, `Rack*`, `Bevel*`, `GearChain*`, `Planetary*`, `GearPreview*` | `schemas.py` |
| Save-file format | gear (de)serialisation | `native_format.py` |
| Feature dispatch | `_gear_feature_response`, `_bevel_*_response`, `_gear_chain_feature_response`, domain<->schema converters, payload validators | `router.py` (kept there on purpose: they plug into the generic `_feature_response` dispatch) |
| Rebuild | `resolve_gear*` etc. called from the body-cache / feature replay | `body_cache.py`, `graph.py`/`router.py` replay |

`gears_routes.py` was cut out of `router.py` mechanically (52 route handlers and route-only helpers, about 1,600 lines).
Checks run when it was split: the registered route list (235 routes) and the generated OpenAPI document are byte-identical
before and after, and no code left in `router.py` uses anything that moved.

Rules for the new module:
- It has no prefix or dependencies of its own; `router` supplies `/document`, the tag and `bind_session_id`.
- Import `app.document.router`, never `gears_routes` directly (it needs the router's helpers to exist first).

## Tests: running gears separately

`backend/tests/conftest.py` tags every module named `test_*(gear|bevel|rack|planetary)*.py` with the `gears` marker
(451 of 2,716 tests at the time of writing).

```bash
cd backend
pytest -m "not gears" -n auto --dist=worksteal      # everything else: the fast loop
pytest -m gears -n auto --dist=worksteal --ignore=tests/test_planetary_gear_jobs.py   # gears only
pytest tests/test_planetary_gear_jobs.py            # always serial
```

CI (`backend-verify.yml`) runs the two groups as parallel matrix legs per platform, with Docker layer caching shared between
them, so wall-clock is the slower leg rather than the sum.

## Client

Already mostly isolated in `client/lib/gear/` (design screens, preview canvases, presets). Touchpoints elsewhere:
`api/document_api_client.dart` (DTOs and calls), `viewport3d/part_screen.dart` and `feature_tree_panel.dart` (tool entry
points, tree icons/labels), `viewport3d/pending_job_store.dart` (background jobs), `tool_chooser_screen.dart`, the `ai/`
planner files, `materials/`, `config.dart`, `mesh_viewer/` settings.

## Next steps (not done)

1. Move the gear DTOs/clients out of `document_api_client.dart` into `client/lib/gear/`.
2. Move gear schemas out of `schemas.py` and the gear feature classes out of `models.py` into gear-only modules (re-exported
   from the old names first, so nothing else changes).
3. Give features a registry (`register_feature_type(name, model, schema, response_fn, builder)`) so `router.py`,
   `native_format.py` and `body_cache.py` stop naming each gear type. That registry is also the plugin boundary a downloadable
   module would need; do it only once 1-2 show the seams are clean.
4. Only then decide on a separate package. A downloadable module cannot ship executable code on iOS.
