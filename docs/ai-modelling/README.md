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

## Spikes (do these first, before committing to the real build)

Two throwaway-code spikes, both aimed at finding a showstopper early —
same purpose the gear design tool's own pre-build spikes served:

1. **Structured-output reliability spike.** Before investing in the
   translator, confirm a realistic spread of models — a strong cloud
   model and at least one mid-weight local model via Ollama — reliably
   emit valid JSON matching workstream 3's plan schema, across a handful
   of representative prompts (a simple bracket, a gear-shaped request, a
   deliberately ambiguous one). Determines whether workstream 1's
   "advisory-only capability flag + fallback JSON extraction" design is
   enough on its own, or whether weaker local models need a stronger
   retry-with-error-feedback loop from day one. Also the place to test
   whether 1-2 few-shot examples in the system prompt (see
   `02-scoping-conversation.md`) meaningfully improve reliability over
   instructions alone — expect they will, but confirm rather than assume.
2. **Edge-selector heuristic spike** — `03-structured-plan-schema.md`'s
   own flagged open problem. Build the `top_face_edges`/`vertical_edges`/
   etc. selectors against a simple test box's real `MeshDto` and confirm
   they identify the right edges before the plan schema locks for real.

### Testing without cost

Options confirmed for spike 1 (checked mid-2026 — re-verify before use,
these terms shift often):

- **Ollama Cloud** ($0 free tier, GPU-time metered, no payment info
  required to sign in) proxies frontier-scale open-weight models — GLM-
  5.2, DeepSeek-V4-Pro, Kimi-K2.6 — too large for real local hardware,
  through the **same Ollama API surface** the local-provider slot already
  targets. Point the local-provider `baseUrl` at Ollama Cloud's endpoint
  instead of a real local server for free testing against frontier-class
  open models with zero new code — see `01-provider-abstraction.md`'s own
  cross-reference note. This also means the local-provider slot isn't
  strictly LAN-only in practice, a genuine architectural nuance beyond
  just a way to save money on this spike.
- **Google Gemini** and **Groq** both have real, ongoing (not one-time)
  free tiers and both speak the OpenAI-compatible dialect
  `OpenAiCompatibleProvider` already implements — zero new code, good for
  the "realistic cloud model" side of the spike without spending
  Anthropic's one-time credit.
- **DeepSeek, Kimi (Moonshot), GLM (Zhipu)**: all open-weight, all
  OpenAI-compatible on their own hosted APIs, all confirmed structured-
  output/tool-calling support — cheap even where not free, and reachable
  via Ollama Cloud's free tier regardless, per the point above.
- **Qwen (Alibaba)**: worth including in the spike for two different
  reasons — the only one of these confirmed to run practically on modest
  *actual* local hardware (not just "open weight" in the abstract, real
  Ollama/llama.cpp-runnable smaller variants), and the clearest vision
  story of the bunch (dedicated Qwen-VL variants) — the latter matters
  for workstream 6 later, not this spike, but worth testing while it's
  already in scope for the structured-output side.
- **Anthropic's one-time ~$5 credit**: save it for a final confirmation
  pass once the schema/prompt is stable from testing against the free
  options above, rather than spending it on early iteration.

## Delivery order / phased sessions

Roughly 5-6 sessions, in dependency order — each row is a plausible
single-session unit of work, matching this project's own established
per-session granularity (see `docs/status.md`'s history):

| Session | Work | Milestone |
|---|---|---|
| 1 | Both spikes above | De-risked: know whether the schema/prompting approach actually works on realistic models, before writing any production code |
| 2 | Workstream 1 (provider abstraction + settings, incl. the Ollama model-list bolt-on) | Settings panel usable standalone — pick a provider, "Test connection" succeeds |
| 3 | Workstream 3 (lock schema using the spike's findings, incl. resolved edge-selectors) + Workstream 5 (backend dry-run endpoint) | Natural pairing — 5 is small and depends directly on 3's step shapes |
| 4 | Workstream 2 (chat screen + system prompt, incl. the save-plan-as-preset bolt-on) | Can hold a full scoping conversation and see a plan proposed, even before generation works |
| 5 | Workstream 4 (translator + execution, incl. the "Undo this generation" bolt-on) | **First end-to-end usable version** — AI Modelling tile to real Feature-tree part |
| 6+ | On-device feedback round(s) | This project's typical pattern after any client-heavy build — real bugs from a real device/model combo, not assumed working from sandbox-only verification |
| Later, separate arc | Workstream 6 (image input) | Its own multi-session R&D once text mode is proven — don't pull this forward |

## Bolt-ons folded into v1

Cheap, high-value additions decided alongside the core plan — each lands
inside the workstream that already owns the relevant code, not as a
separate workstream:

- **"Undo this generation."** This app has **no Feature-tree-level Undo**
  at all (confirmed by direct check — only per-interaction undo, e.g. a
  sweep-path pick, and manual delete/cascade-delete). Since the
  translator (workstream 4) already tracks every real Feature id it
  creates in order, exposing one button that deletes them in reverse
  (reusing the existing single-Feature/cascade-delete endpoint) is the
  only clean way to back out a whole AI-generated sequence — see
  `04-translator-and-execution.md`'s own section.
- **Save-plan-as-preset**, reusing `GearPresetStore`'s exact pattern
  (client-local, `shared_preferences`, discriminated by `kind`) — see
  `02-scoping-conversation.md`.
- **Ollama model-list fetch** for the local-provider settings field (a
  dropdown from Ollama's native `/api/tags`, falling back to free text) —
  see `01-provider-abstraction.md`.

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
- **v1 always starts a fresh Part**, never adds to whatever Part happens
  to already be open — the simpler of two options considered. Additive
  generation (referencing/extending existing geometry) is real,
  deliberately deferred scope, not designed here: it would need the
  system prompt to carry a compact summary of the current Feature tree
  and the translator to reconcile plan-local ids against real
  pre-existing ones from the first step, neither of which v1 needs.
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
