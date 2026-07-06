# Live-edit preview pattern

Reference doc for implementing a new Feature type whose panel needs to show
live feedback while the user is still adjusting it (radius, distance, which
sub-shapes are picked, ...). Written after Fillet (Prompt D + its on-device
follow-ups) needed a real fix for a bug this exact question caused -
`docs/status.md`'s entries from 2026-07-05 have the full incident history if
you want the "why" in more detail than this doc restates. This file is the
"how do I add the next one" lookup; `status.md`/`roadmap.md` are dated
narrative logs, not meant to be searched for a recipe.

Audited against this doc while writing it: Extrude (Boss/Cut) and Create
Plane. Neither needs any change - see "Existing Features" below for why, so a
future agent doesn't go looking for a bug that isn't there. Chamfer (Prompt
E) was built after this doc existed and follows the stable-pick-body +
preview-overlay pattern exactly, reusing `PartViewport`'s two generic fields
with no changes - see "Existing Features" below for specifics.

## The problem, in one paragraph

A Feature panel that lets the user keep picking things in the viewport while
it's open has two needs that can conflict: (1) the ids it's picking against
must stay valid across every edit, so an in-progress selection never breaks;
(2) the user usually wants to *see* what the current radius/distance/edge
selection actually produces. If the Feature being edited modifies the exact
shape you're picking sub-shapes from (e.g. Fillet's `edge_refs` name edges of
the Body the Fillet itself rounds), showing the *actual, current* result as
the only mesh available for picking breaks need (1): the operation's own
effect renumbers/replaces the very ids you're trying to keep referencing,
and the next pick sends a `missing_reference` 422. That's exactly what
happened to Fillet - see the two 2026-07-05 status.md entries titled around
"missing_reference" and "live rounded-corner visual preview" for the full
before/after.

## Decision tree for a new Feature type

**1. Does it modify or produce Body-level geometry at all** (`produces ==
Produces.BODY` / `produces_solid_geometry == True` in
`backend/app/document/models.py`)?

- No (a Sketch, a Plane, anything that doesn't touch a Body's shape) - no
  mesh preview needed. Create Plane is this case: it never changes any
  Body's shape, so there's nothing for a live preview to show in the first
  place - its own "preview" (`_previewCreatePlaneFeatureId` in
  `part_screen.dart`) just means "eagerly-created Feature being live-PATCHed
  in the background", the same shape as every other create-eagerly-on-open
  Feature panel in this codebase, with **no** mesh-level implications. Stop
  here.

**2. Does the live-edit session let the user re-pick sub-shapes (edges/
faces/vertices) of the *same* Body the Feature is currently modifying?**

- No, only Body-level picks (Extrude's Boss/Cut `target_body_ids`) - use
  the simple pattern: the live "bodies" list *is* the actual current result,
  rendered translucent-tinted via `PartViewport.isPreviewMesh` (a single
  global bool covering every Body in the list). This is safe because a
  Body's *id* is stable across re-solves of the very Extrude naming it -
  Boss mints a deterministic new id from the Feature's own id, and Cut's
  split-body `#N` suffixing still resolves back to the same base id
  (`base_feature_id` in `app/document/extrude.py`) - so target_body_ids
  never needs to be re-validated against a "before this Feature's own
  effect" snapshot the way Fillet's `edge_refs` does. No separate preview
  mesh needed; mirror `_openExtrudePanel`/`_ensureExtrudeFeatureExists`/
  `_scheduleExtrudePreview` directly.

- Yes, sub-shape picks of the Body being modified (Fillet's `edge_refs`;
  Chamfer's `edge_refs` is identical, and is in fact built this way already;
  a future Shell/Draft that lets you pick faces of the body it's shelling/
  drafting almost certainly will be too) - use the **stable-pick-body +
  separate preview-overlay** pattern below. This is the one Fillet just had
  to have a real bug fixed to get right - don't skip straight to "just show
  the live result", it will eventually 422.

## The stable-pick-body + preview-overlay pattern (mirror Fillet exactly)

Two meshes, fetched separately, never conflated:

- **The stable/interactive mesh** (`PartScreen._bodies`) - always excludes
  *this Feature's own effect* via `_rollbackExcludedFeatureIds`, for the
  *entire* live-edit session, both the create-new path and the edit-
  existing path. This is what `hitTestBodies`/edge-picking/selection
  highlights all read from - it must never show the operation's actual
  rounded/chamfered/shelled result, only the shape as it was *before* this
  Feature. Backend-side, this relies on the same convention
  `resolve_fillet` already established (`app/document/fillet.py`): the
  resolver used for validating a create/update always computes
  `compute_part_bodies(part, excluded_feature_ids | {feature.id})` -
  excluding the Feature's *own* id in addition to whatever the caller
  already excludes - so re-validating an edit is checked against the Body
  as it was before this Feature, not stacked on top of its own prior
  effect. Any new resolver (`resolve_chamfer`, etc.) needs the identical
  self-exclusion line.

- **A preview-only mesh** (`PartScreen._filletPreviewMesh`/
  `_filletPreviewBodyId` - rename per-feature, e.g. Chamfer's own
  `_chamferPreviewMesh`/`_chamferPreviewBodyId`, kept as a fully separate
  field pair rather than a shared one even though only one live-edit panel
  is ever active at a time, matching this codebase's existing
  duplicate-rather-than-share convention) - the *same* `GET /mesh`
  endpoint, but with this Feature's id **not** excluded, so it reflects the
  actual current radius/edges/whatever. Fetched by
  `PartScreen._refreshFilletPreviewMesh` (mirror this function's shape
  exactly for a new Feature type, e.g. `_refreshChamferPreviewMesh`) - note
  it computes its exclusion set as
  `_rollbackExcludedFeatureIds.where((id) => id != featureId)`, i.e. "every
  exclusion currently active, minus this one Feature's self-exclusion",
  not just "no exclusions" - that matters once B4 rollback is *also*
  active for a downstream edit (features after the one being edited stay
  excluded either way).

- **Rendering**: `PartViewport.previewOverlayBodyId`/`previewOverlayMesh`
  are already generic (not Fillet-specific in name or behavior) - a new
  Feature type reuses these two fields directly, no `PartViewport` changes
  needed; confirmed by Chamfer's own rollout, which wired
  `previewOverlayBodyId`/`previewOverlayMesh` to a ternary
  (`_filletActive ? filletPreview : chamferPreview`) with zero changes to
  `PartViewport` itself. `_syncMeshNode`/`_syncEdgesNode` substitute the
  preview mesh (rendered with the same translucent orange tint
  `isPreviewMesh` uses) for the rendered Node of the one Body whose id
  matches `previewOverlayBodyId` - `bodies` itself, and everything reading
  from it (hit-testing, selection highlights), is completely untouched. If
  a third concurrent live-edit flow is ever added on top of Fillet and
  Chamfer, `previewOverlayBodyId`/`previewOverlayMesh` would need to become
  a list instead of a single pair; don't build that until it's an actual
  requirement.

- **Concurrency**: run the stable-mesh refresh and the preview-mesh fetch
  together via `Future.wait` (see `_ensureFilletFeatureExists`), not one
  after the other - this is two full OCCT recomputes on the backend per
  debounced edit instead of one, and running them sequentially would double
  the round-trip latency the user feels on top of that. `Future.wait` keeps
  the felt latency roughly the same as a single request; the backend CPU
  cost is still doubled per edit, which is a real, known trade-off (flagged
  in the 2026-07-05 status.md entry) - worth re-checking on real Pi 5
  hardware once more than one live-preview-hungry Feature type exists
  side by side in typical usage.

- **Lifecycle**: create-path and edit-path both need the self-exclusion
  added the moment a real Feature id exists - Fillet's bug was specifically
  that the *create* path forgot this (the *edit* path, via
  `_openFilletPanelForEdit`'s `_beginRollback({feature.id})`, already had
  it from Prompt D onward). `_confirmFillet`/`_cancelFillet` both clear the
  preview-mesh state (`_filletPreviewBodyId = null; _filletPreviewMesh =
  null;`) alongside their existing cleanup - don't forget this for a new
  Feature type, or a stale preview overlay could linger into the next
  session.

## Existing Features audited against this doc (no changes made)

- **Extrude (Boss/Cut)**: body-level picking only, body ids stable across
  re-solves - see "Decision tree" step 2 above. Uses the simple
  `isPreviewMesh` pattern already; left as-is deliberately, not an
  oversight. Retrofitting it to the stable-pick-body + overlay shape would
  add a second backend recompute per edit for zero correctness benefit -
  don't do this without a concrete reason.
- **Create Plane**: never modifies Body geometry at all (`produces_solid_geometry
  == False`) - see "Decision tree" step 1. Its own "preview" state
  (`_previewCreatePlaneFeatureId`) is unrelated to mesh rendering; nothing
  to change here either.
- **Chamfer**: built after this doc, as a full mirror of Fillet's
  implementation - same self-exclusion-on-create fix, same
  `_chamferPreviewMesh`/`_chamferPreviewBodyId`/`_refreshChamferPreviewMesh`
  trio, same `Future.wait` concurrency, same lifecycle cleanup in
  `_confirmChamfer`/`_cancelChamfer`. Confirmed working on-device
  (`docs/status.md`, 2026-07-06) - the first real-world validation that this
  doc's pattern generalizes cleanly to a second consumer, not just a
  one-off fix for Fillet alone.
