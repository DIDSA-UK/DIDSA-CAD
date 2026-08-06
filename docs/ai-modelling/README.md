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

**Status**: workstreams 1 (provider abstraction), 2 (scoping conversation),
3 (structured plan schema), and 5 (backend plan validation) are built and
tested — real, committed code, not just this doc set's own original
scoping/brainstorm output. Workstream 4 (translator/execution) and 6
(image input, explicitly deferred) are not yet started.

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
| 3 | `03-structured-plan-schema.md` | — | The JSON plan schema itself, which Sketch entity/Feature types v1 can generate, gear-request routing. Edge selection for Fillet/Chamfer is **resolved** — see its own "Spike 2 findings" section for the four confirmed selector definitions |
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
2. **Edge-selector heuristic spike — done (2026-08-06).** Ran against
   real OCCT-produced geometry (a genuine `pythonocc-core` environment
   bootstrapped in-session, not a hand-built fixture): all four selectors
   (`top_face_edges`, `bottom_face_edges`, `vertical_edges`,
   `all_edges_of_face_at_position`) confirmed correct on a plain box and,
   more importantly, on the realistic multi-step case (selecting vertical
   edges *after* a prior fillet already modified the body). See
   `03-structured-plan-schema.md`'s own "Spike 2 findings" section for
   the exact definitions and the bootstrap recipe for a future session
   that needs real OCCT again (this environment's own build doesn't
   persist).

### Testing without cost

Options confirmed for spike 1 (checked mid-2026 — re-verify before use,
these terms shift often):

**No local install or LAN/server infra needed for any of these** — all
pure HTTPS APIs, directly reachable from a phone-only client with nothing
stood up yet:

- **Ollama Cloud** — genuine, ongoing $0 tier, **no local Ollama install
  required**: reachable directly at `https://ollama.com/v1` with an
  `apiKey` from ollama.com, exactly like OpenAI/Anthropic cloud (a local-
  daemon-proxy path also exists — `ollama signin` +
  `http://localhost:11434/v1` — but isn't needed and is strictly worse
  when there's no reachable local/LAN host). See
  `01-provider-abstraction.md`'s own note — worth its own preset option
  in the settings screen rather than only a manual local-`baseUrl`
  override, given it isn't really "local" at all in practice.
  **Correction from real spike-1 testing (2026-08-06,
  `03-structured-plan-schema.md`'s own findings)**: the frontier-scale
  models named above as free — GLM-5.2, DeepSeek-V4-Pro/Flash, Kimi-K2.6,
  Qwen3.5 — now all return `HTTP 403 "this model requires a
  subscription"` on the free tier. **Confirmed still free** on that same
  pass: `gpt-oss:20b`, `gpt-oss:120b`, `nemotron-3-super`, `gemma4:31b`,
  `minimax-m3`. Ollama Cloud's own free-tier model list moves — re-check
  directly (`GET https://ollama.com/v1/models`) rather than trusting
  either this list or the original one going stale the same way.
- **Google Gemini** and **Groq** both have real, ongoing (not one-time)
  free tiers and both speak the OpenAI-compatible dialect
  `OpenAiCompatibleProvider` already implements — zero new code. Gemini
  has the more generous token allowance (~250k tokens/min); Groq the
  higher daily request count (~14,400/day). **Groq caveat from the same
  spike-1 pass**: every request to `api.groq.com` — with a real key, from
  a genuinely local (non-sandboxed) network — returned `HTTP 403 "Access
  denied. Please check your network settings"`, distinct from a normal
  auth failure. Reads as a network/IP/region-level block on Groq's own
  side for that connection, not an Anthropic-sandbox artifact and not a
  bad key — but genuinely untested end-to-end as a result. Don't assume
  Groq is reachable without checking your own account/network first.
- **Zhipu/GLM**: two of its smaller models — GLM-4.5-Flash and
  GLM-4.7-Flash — are priced at $0 **permanently**, not a time-limited
  trial, on Zhipu's own official API. A genuine fourth always-free
  option, direct HTTPS, no local component.
- **DeepSeek**: a one-time 5M-token trial grant (~30 days) on sign-up,
  not an ongoing free tier — fine for a single concentrated testing
  burst, then a payment method is required. Still reachable indefinitely
  via Ollama Cloud's free tier regardless, per the point above.
- **Kimi (Moonshot)**: **no free tier on its own API at all** (only the
  consumer chat app is free; API access needs a minimum $1 top-up) —
  drop this from the free-testing list; still reachable via Ollama
  Cloud's free tier if wanted.
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
