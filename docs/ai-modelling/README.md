# AI Modelling

An AI-assisted modelling entry point for DIDSA-CAD's Flutter client: a user
describes a part in plain English (v1) or — a later, explicitly deferred
workstream — uploads a photo of a sketch/drawing, an LLM asks clarifying
questions to scope the request, then a deterministic translator turns the
resulting structured plan into a real Feature-tree part built through this
app's own Sketch/Feature API — as editable afterward as anything built by
hand. The user picks their AI provider (local or cloud) from a new settings
panel alongside the existing `SketcherSettingsScreen`/`MeshViewerSettingsScreen`
precedent.

**Status: scoped, not started.** This doc set is the output of the
investigation/brainstorm session that produced it — no code has been
written yet.

## How to use these docs in a fresh implementation session

**Read `00-conventions.md` first, always** — it holds every fact/decision
referenced by 2+ workstreams (the provider abstraction shape, the
structured-plan schema's place in the architecture, settings/preferences
conventions, the failure-handling/retry model, the v1 scope boundary).
Workstream files don't repeat it.

Then read **only the one workstream file you're implementing**, plus
whatever it names as a dependency — same discipline `docs/gear-design/`
established (a prior single-file version of that doc grew past 1000 lines;
a session implementing one workstream never needed most of it).

## Workstreams

| # | File | Depends on | Notes |
|---|------|-----------|-------|
| 1 | `01-provider-abstraction.md` | — | The `AiProvider` Dart interface, `OpenAiCompatibleProvider` (OpenAI cloud + local Ollama-style endpoint, same wire shape), `AnthropicProvider` adapter, settings screen + preferences |
| 2 | `02-scoping-conversation.md` | 1 | The chat panel UI, transcript management, system-prompt design, plan-review handoff |
| 3 | `03-structured-plan-schema.md` | — | The JSON plan schema itself, which Sketch entity/Feature types v1 can generate, gear-request routing. **Has one flagged unresolved design problem** (edge selection for Fillet/Chamfer) — read its own "Open design problem" section before implementing |
| 4 | `04-translator-and-execution.md` | 1, 2, 3, 5 | Client-side `PlanTranslator` driving the real `DocumentApiClient`/`SketchApiClient`, failure handling, no auto-rollback |
| 5 | `05-backend-plan-validation.md` | 3 | The one backend addition: a stateless dry-run plan-validation endpoint |
| 6 | `06-image-input-deferred.md` | 1, 2, 3 | Explicitly **not v1** — image upload, vision strategy, scope cut lines, recorded for when this becomes the active workstream |

## Delivery order

1. **Workstream 1** — no dependencies, needed by everything else (even a
   throwaway scoping-conversation spike needs a way to call a provider).
2. **Workstream 3**'s schema design, in parallel with/right after 1 — the
   riskiest, most foundational artifact in this doc set (everything else
   is plumbing around it). Resolve its flagged edge-selection problem
   before locking the schema.
3. **Workstream 5** — small, and workstream 4 can't be tested end-to-end
   without it (or at least a stub of it).
4. **Workstream 2** — the chat UI, once there's a provider to talk to and
   a schema to ask for.
5. **Workstream 4** — wires 1-3 and 5 together into the real generate
   button. This is the first point the feature is actually usable
   end-to-end.
6. **Workstream 6** — a deliberately separate, later phase. Don't start it
   until 1-5 are proven on text input; it has its own real R&D risk (a
   dedicated vision/OCR extraction step) that shouldn't be taken on at the
   same time as the rest of this feature.

## Key decisions carried through every workstream (don't re-litigate)

These were resolved during this session's scoping conversation — see each
workstream file for the reasoning, but treat the decisions themselves as
settled unless new information genuinely changes the tradeoff:

- **Client-direct, not backend-broker.** The Flutter client calls the
  active AI provider directly (local or cloud) — the CAD backend is not in
  the loop for the LLM call itself, and gains **no new AI-brokering
  endpoint**. The one exception is workstream 5's dry-run validation
  endpoint, which is a plain compute-only Feature-resolution endpoint, not
  an AI broker.
- **Structured plan + deterministic translator, not freeform tool-calling.**
  The LLM emits a JSON plan (workstream 3); a client-side translator
  (workstream 4) turns it into real, ordinary `DocumentApiClient`/
  `SketchApiClient` calls — the exact same calls a human-driven screen
  like `GearChainDesignScreen` already makes. The LLM never calls the
  Feature API directly mid-conversation in v1.
- **Provider wire protocol**: unified on the OpenAI-compatible
  chat-completions shape for every provider except Anthropic (which isn't
  wire-compatible with it) — `OpenAiCompatibleProvider` covers OpenAI
  cloud and any local Ollama-style endpoint (Ollama speaks this dialect
  natively) with the same code; `AnthropicProvider` is one dedicated
  adapter alongside it, not a second parallel architecture.
- **Curated cloud provider list for v1**: OpenAI and Anthropic. Local is
  "any OpenAI-compatible HTTP endpoint the user points the app at" —
  concretely an Ollama-style server, but not hardcoded to Ollama by name.
- **Scoping UX**: an inline chat panel (matches how this very scoping
  session worked), not an LLM-proposed structured form.
- **v1 scope boundary**: single current Part; Sketch geometry composed
  only from existing entity types (Point/Line/Circle/Arc/Ellipse/
  Rectangle/Polygon/Slot); Feature sequence composed only from existing
  Feature types (Sketch/Extrude/Revolve/Sweep/Fillet/Chamfer/Pattern/
  Mirror/CreatePlane), plus Gear/Rack via routing to the existing entry
  screens rather than freeform generation. No multi-Part assemblies (this
  app has no multi-Part UI concept yet), no Loft/GearChain/Planetary/
  BevelGear/BevelPair/Import as direct generation targets, no Spline/Text
  as generation targets. See `00-conventions.md` for the full list and why.
- **No automatic rollback on a failed step.** Matches this app's existing
  no-destructive-auto-action posture — a failed generation leaves
  already-created Features in place and hands the real error back to the
  LLM as a chat turn; the user's ordinary Undo/delete-Feature tools are
  how manual cleanup happens if needed.
- **Image input is real scope, deliberately not v1.** Text-only ships
  first, proven end-to-end, before image upload becomes the active
  workstream — see `06-image-input-deferred.md`.
