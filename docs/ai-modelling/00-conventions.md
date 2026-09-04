# AI Modelling — Shared Conventions

Read this before implementing **any** workstream. It holds facts and
resolved decisions referenced by two or more workstreams; each workstream's
own file holds only what's specific to it. Don't duplicate this content
into a workstream file — link back here.

Client: new `client/lib/ai/` directory (mirrors `client/lib/gear/`'s own
self-contained shape). Backend: one new endpoint in
`backend/app/document/router.py` (workstream 5) — no new backend module
tree, since v1 introduces no new Feature or Sketch entity type.

## Why client-direct, and what that does and doesn't change

The client calls the active AI provider's HTTP API directly — Flutter's
`http` package, same as every other network call this app already makes.
The CAD backend never sees the LLM conversation and gains no AI-brokering
endpoint. This was a deliberate call (see `README.md`'s key decisions), not
a default — the alternative (a backend broker keeping cloud keys
server-side) was seriously considered and rejected in favour of this
shape.

**What this means concretely:**
- Cloud provider API keys are entered and stored client-side, the same
  trust boundary `ApiConfig`'s own `api_key` field already establishes for
  the backend's shared key (`client/lib/config.dart`) — not a new kind of
  risk for this app, just a second secret living the same way.
- A local provider (an Ollama-style endpoint) must be reachable from
  wherever the *client* is running, not from the backend. On the same
  Wi-Fi as the local server this is trivial; if the client is used
  remotely (this app's backend is deliberately internet-facing via
  Cloudflare Tunnel per the project brief), a local provider configured
  with a LAN-only address simply won't be reachable — a real, accepted
  limitation of this architecture, not a bug to fix. Worth a one-line
  callout in the settings screen itself (workstream 1), not a blocker.
- The one thing that *does* still touch the backend is workstream 5's
  dry-run validation endpoint and, on a "Generate" press, the perfectly
  ordinary sequence of real `DocumentApiClient`/`SketchApiClient` calls
  workstream 4's translator makes — identical in shape to what any other
  guided screen (`GearChainDesignScreen`, etc.) already does. The AI
  feature is a new *caller* of the existing API, not a new part of it.

## The provider abstraction (full detail in `01-provider-abstraction.md`)

One Dart interface (`AiProvider`), two implementations
(`OpenAiCompatibleProvider`, `AnthropicProvider`), selected at runtime by a
new `AiProviderPreferences` (settings, `shared_preferences`-backed, same
load()/setX() pattern as `SketcherPreferences`/`ApiConfig`). Every
consumer above the interface (the scoping-conversation UI, the translator)
talks to `AiProvider` only, never to a concrete provider type.

`OpenAiCompatibleProvider` is parameterized by `baseUrl`/`apiKey`/`model`
and covers **both** OpenAI cloud and any local Ollama-style endpoint —
they speak the same `POST {baseUrl}/chat/completions` wire shape, so one
implementation serves both; only the configured `baseUrl`/`apiKey` differ
(local typically has no key). `AnthropicProvider` is a separate adapter
because Anthropic's native Messages API isn't wire-compatible with that
shape — it translates to/from the same internal transcript/turn-result
types everything else uses, so nothing above the interface has to know
the difference.

## Settings/preferences convention

New `AiProviderPreferences` (mirrors `ApiConfig`/`SketcherPreferences`
exactly): which provider is active, plus each provider's own
`baseUrl`/`apiKey`/`model` fields. New `AiProviderSettingsScreen`.

**Placement**: a new entry inside the existing `SketcherSettingsScreen`
("CAD Settings," reached from `ConnectionScreen`'s settings icon) rather
than a new icon on `ConnectionScreen` itself. `SketcherSettingsScreen`'s
own doc comment already anticipates this ("this is the CAD side's one
settings screen for now") and `ConnectionScreen`'s Connect/Settings button
row is already a tight 80/20 split with no spare room for a third icon
without reflowing it. `AiProviderSettingsScreen` is still its own full
screen (API keys and multiple provider configs are more than a toggle
belongs on the same page as), just reached via a new list entry inside CAD
Settings rather than a new top-level icon.

## The structured-plan schema's place in the architecture

Full schema in `03-structured-plan-schema.md`. The short version every
other workstream needs: the LLM's job ends once it emits one JSON object —
an ordered list of "steps," each naming a Sketch entity or Feature to
create, referencing earlier steps by a plan-local id. Nothing is created
against the real backend until the user presses "Generate." This is what
makes workstream 5's dry-run validation possible at all (a plan is data,
checkable before anything real happens) and what keeps workstream 4's
translator deterministic (it walks a fixed list, not a live conversation).

## Feature-tree checklist: not applicable, and why

`docs/gear-design/00-conventions.md`'s six-part checklist (dataclass →
`depends_on` → `resolve_X` module → `compute_part_bodies` branch → schemas
→ router endpoints) is how this codebase adds a **new Feature type**. This
feature doesn't do that — v1 composes only Feature/Sketch-entity types
that already exist. The one new backend surface (workstream 5's endpoint)
only needs checklist item 6 (a router endpoint); items 1-5 are all reused
verbatim from whichever existing Feature types a given plan happens to
use.

## v1 scope boundary — the exact allowed set

**Sketch entity types the LLM can generate**: Point, Line, Circle, Arc,
Ellipse, Rectangle, Polygon, Slot.

**Sketch entity types deliberately excluded from v1 generation**: Spline
(solver-backed, built for interactive point-by-point dragging — the same
"not built for bulk/parametric generation" reasoning
`docs/gear-design/00-conventions.md`'s "gear teeth are not Sketch
entities" section already established for a different bulk-geometry case);
Text (no clear use case for AI-authored text labels here).

**Feature types the LLM can generate**: SketchFeature, ExtrudeFeature,
RevolveFeature, SweepFeature, LoftFeature, FilletFeature, ChamferFeature,
PatternFeature, MirrorFeature, CreatePlaneFeature, MergeFeature,
BooleanFeature, DeleteBodyFeature, ScaleBodyFeature, MoveBodyFeature.

LoftFeature was excluded at first pass (see below for why it was added
back) and MergeFeature/BooleanFeature/DeleteBodyFeature/ScaleBodyFeature/
MoveBodyFeature simply postdate the original v1 scoping pass and were
never revisited until now — none of the six were a deliberate, permanent
exclusion the way the ones below are.

**Feature types deliberately excluded from v1 generation**: GearFeature/
RackFeature (routed to the existing Gear Design screens instead — see
below, not generated as raw Feature-tree steps), GearChainFeature/
PlanetaryGearFeature/BevelGearFeature/BevelPairFeature (all high-
complexity, multi-body, or gear-adjacent — out of reach for a first
structured-plan schema), SplitFeature/SurfaceFeature/DeleteFaceFeature/
MoveFaceFeature (face-level or multi-body-splitting complexity, deferred
alongside the gear-adjacent set above), ImportFeature (there is no file
for the LLM to import).

**AI Settings → Tools toggles**: every Feature type above except Sketch/
Extrude can be individually turned off per-user (`client/lib/ai/
ai_tool_groups.dart`), shrinking the system prompt and having the LLM
actively decline and point at the manual UI tool instead of proposing a
plan that uses it — enforced structurally by `PlanValidateRequest.
disabled_kinds` (`ai_plan_schemas.py`), not just by prompt wording. This is
orthogonal to the "deliberately excluded" list above: a toggled-off tool
still exists in this schema and can be turned back on; an excluded one
does not exist in the schema at all.

**Gear-request routing**: when the scoping conversation's system prompt
(workstream 2) recognizes gear intent, the LLM is instructed to emit a
distinct step kind naming gear parameters instead of a generic Feature
sequence; the translator (workstream 4) hands that off to the existing
`GearDesignScreen`/`GearChainDesignScreen`/`BevelDesignScreen` pre-filled,
rather than attempting freeform generation. This is a real v1-scope-
shrinker precisely because the gear tool is now complete
(`docs/gear-design/`) — not a hypothetical.

**No multi-Part assemblies.** This app has no "pick an existing Part" or
multi-Part UI concept at all yet (see `NativeImportResultDto`'s own doc
comment).

**v1 always starts a fresh Part.** Unlike the Gear Design entry screens
(which add to whatever Part is already open, creating one via `createPart`
first if none is), AI Modelling always creates a brand-new Part via
`createPart` when the user presses "Generate" — it never targets an
already-open Part. Decided this way specifically to avoid needing the
system prompt to carry existing-geometry context or the translator to
reconcile plan-local ids against real pre-existing ones — both real,
deliberately deferred scope (see `README.md`'s key decisions). This does
mean the AI Modelling entry point is really "start a new part with AI
help," not "AI-assist my current part" — worth being explicit about in
the tile's own subtitle text (workstream 2).

## Failure handling and the no-auto-rollback decision

Two layers, not one:

1. **Pre-flight (workstream 5)**: before any real Feature is created, the
   full plan is dry-run validated against the real backend Part
   (in-memory, never persisted) via a purely structural/geometric check —
   catches malformed references, bad enum values, and most geometry
   failures before touching the user's real Part at all.
2. **Real execution (workstream 4)**: the translator then executes the
   (already dry-run-passed) plan for real, step by step. A step can still
   fail for real even after passing dry-run (e.g. a numeric edge case a
   dry run's simplified checks don't model exactly) — on a real failure,
   execution **stops immediately**. Every Feature already created up to
   that point is left in place. **No automatic rollback** — matches this
   app's existing posture against destructive automatic actions (see the
   top-level system instructions this whole project already operates
   under, and this codebase's own convention of never silently discarding
   user-visible state). The real error text is surfaced back into the
   chat as a new turn; the user can ask the LLM to propose a revised plan
   for the remaining steps, or clean up manually.

   **Cleanup note**: this app has no Feature-tree-level Undo at all (only
   per-interaction undo, e.g. a sweep-path pick, plus manual delete/
   cascade-delete) — so "clean up manually" without more would mean
   deleting each AI-created Feature by hand, one at a time. Workstream 4
   adds a dedicated "Undo this generation" action for exactly this reason
   (a bolt-on decided alongside this plan, not a pre-existing app
   capability) — see that file's own section.

This directly resolves one of the original scoping prompt's own open
questions ("full rollback vs. partial result vs. non-blocking
validation-banner pattern") in favour of the partial-result path, on the
grounds that this codebase has no Feature-tree rollback mechanism to reuse
anywhere else, and building one solely for this feature would be new,
unscoped engineering. Flagged explicitly here since it's a real design
choice, not an obvious default.

## Non-blocking validation banner convention

Reused as-is, unchanged: any warning a real Feature-creation call returns
during workstream 4's execution (undercut risk on a routed gear request,
a self-intersecting Loft — not applicable to most v1 steps, but the
convention still applies wherever it's already wired into an existing
Feature type) surfaces to the user exactly the way it would if they'd
built the same Feature by hand. No new validation-banner mechanism for
this feature.

## Entry point

A new "AI Modelling" tile on `ToolChooserScreen`, following the exact
`_ToolTile` pattern `Gear Design`'s own tile already established, landing
on a new `AiModellingScreen` (workstream 2's chat panel).
