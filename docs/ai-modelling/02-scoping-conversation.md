# Workstream 2: Scoping Conversation

Read `00-conventions.md` first. Depends on workstream 1 (needs an
`AiProvider` to talk to).

## `AiModellingScreen`

Reached from `ToolChooserScreen`'s new "AI Modelling" tile
(`00-conventions.md`'s Entry point section). An inline chat panel —
message list (user/assistant turns) + text input + send button — the
decided UX (see `README.md`'s key decisions: chat panel, not an
LLM-proposed structured form).

Conversation state (`List<AiChatMessage>`) lives entirely in this screen's
Dart state, never persisted server-side anywhere — the whole transcript is
resent on every `sendScopingTurn` call (workstream 1), the same "client
holds the authoritative state, server call is a pure function of what's
sent" shape the Document API itself already uses for Part state, just
applied to a conversation instead of a Feature tree.

## System prompt

Sent as the first message (or the `system` field, for providers that have
one — `AnthropicProvider` maps it there; `OpenAiCompatibleProvider` sends
it as a `system`-role message). Five components, all static/hand-written
for v1 (not derived from any live schema — see the maintenance note at
the end):

1. **Role/premise.** A short framing: "You are a CAD modelling assistant
   for DIDSA-CAD, a parametric 3D CAD tool. Your job is to have a short
   conversation with the user to fully specify a mechanical part, then
   respond with exactly one JSON plan matching the schema below — nothing
   else in that final message." Also states the fresh-Part framing
   plainly (`00-conventions.md`): this always builds a new part, never
   modifies one that already exists.
2. **The exact allowed vocabulary** — a compact, machine-readable
   reference for every `kind` workstream 3's schema supports (Sketch
   entities, Features): name, fields, units, valid enum values. This is
   the model's *only* source of truth for what it can generate — the
   model should be told explicitly what it **can't** (Spline, Text, Loft,
   assemblies, etc.) so a request that needs one of those gets a
   clarifying pushback ("I can approximate this with a Rectangle +
   Fillets, would that work?") rather than a plan referencing a step kind
   the translator doesn't understand.
3. **Units convention**: mm for every length/distance field, degrees for
   every angle — stated explicitly rather than left implicit, since the
   plan schema's numeric fields carry no unit type of their own (matching
   how the underlying Feature API itself has no unit field either).
4. **1-2 worked few-shot examples** — a short example conversation and
   its resulting plan, embedded directly in the prompt. Expected to do
   more for reliable structured output than the instructions above alone,
   especially on weaker local models — this is the first thing to tune
   based on workstream 1's own structured-output reliability spike
   findings (`README.md`).
5. **Ask before generating, gear intent, termination shape**: keep asking
   clarifying questions (missing dimensions, ambiguous features,
   tolerances) until confident — mirrors this very scoping session's own
   working style, the explicit precedent named in the original ask.
   Prefer the gear-routing step kind over a generic Feature sequence when
   the request is gear/rack-shaped. Once ready, respond with *only* the
   plan, fenced/embedded so workstream 1's plan-detection fallback can
   reliably extract it regardless of whether the active provider's
   structured-output support is confirmed.

**Maintenance note**: the vocabulary reference (component 2) is a
hand-maintained copy of workstream 3's real schema, not generated from it
— if a future session adds a field to an existing step `kind`, this
prompt needs a matching manual update or the LLM won't know the field
exists. Worth a code comment pointing back here wherever workstream 3's
schema types are defined, so the two don't silently drift.

## Plan-review handoff

Once `AiTurnResult.plan` is non-null, the panel switches from "still
chatting" to a **Review & Generate** state:

- A human-readable summary of the plan's steps (e.g. "1. New Sketch on
  XY  2. Rectangle 60×40mm  3. Extrude 10mm  4. Fillet 4 edges @5mm" —
  derived from the plan data, not raw JSON shown to the user).
- **Generate** button — runs workstream 5's dry-run validation, then (on
  success) workstream 4's real translator.
- **Adjust** — drops back into chat mode; the next user message is sent
  with the full transcript *plus* the just-proposed plan included as
  context, so the LLM revises rather than starting over.

## Bolt-on: save plan as preset

Reuses `GearPresetStore`'s exact mechanism (client-local,
`shared_preferences`, one `GearPreset.kind` discriminator string per
screen type) rather than building a new store — add a new kind (e.g.
`'ai_modelling_plan'`) whose `fields` map holds the finished plan JSON
(and optionally the transcript that produced it). Available once a plan
has been proposed (the Review & Generate state above): "Save as preset"
alongside "Generate"/"Adjust," and a "Load preset" entry point when
starting a fresh conversation, pre-populating the Review & Generate state
directly without needing to re-run the scoping conversation at all. Same
"convenience for re-populating, not a live link" framing
`GearPreset`'s own doc comment already establishes — loading a preset and
generating produces an ordinary, independent Feature sequence with no
ongoing relationship to the preset it came from.

## Scope note

No image handling in this workstream — text input only. Workstream 6
extends `AiChatMessage` and this screen's input row once it becomes the
active workstream; nothing here should be built in a way that blocks that
extension (e.g. don't hardcode the input row to text-only in a way that's
awkward to add an attach-image affordance to later), but don't build any
image UI now either.
