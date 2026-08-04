# Workstream 9 — Gear parameter presets/templates (client-local)

Read `00-conventions.md` first. Depends on Workstream 8 (the form it
saves/loads state from). No backend involvement.

## Scope

A named-preset store for gear parameters (module, teeth, pressure angle,
type, etc.), reusable across Parts/sessions. **Client-local** (on-device
storage — the same mechanism `SketcherPreferences`/`MeshViewerPreferences`
already use), deliberately not a new server-side store: this app's
backend has held a genuine "stateless, persists no model data" principle
(`docs/project-brief.md` §3) through every Feature built so far, and a
preset store is the first thing that needs to outlive a single session's
Part — worth keeping that boundary intact rather than crossing it
incidentally. If cross-device preset sync is ever wanted, that's a
separate architectural decision to make explicitly, not a side effect of
building presets.

UI: a "Save as preset" action on the Gear Design screen capturing the
current form state under a user-given name, and a picklist/gallery to
load one back into the form. Presets are a convenience for
*re-populating the form*, not a live/associative link — loading one and
creating a gear produces an ordinary, independent Feature with no ongoing
relationship to the preset it came from.

## Complexity/risk

Low. Pure client-side, no backend surface, no interaction with the
Feature-tree/dependency-graph model — UI convenience state, not part of
any Part's document. Exact storage mechanism (Flutter's usual local-
prefs/file-based options) is a small, ordinary implementation choice.
