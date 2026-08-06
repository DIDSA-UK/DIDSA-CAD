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
it as a `system`-role message). Must establish:

1. **The exact allowed vocabulary** — the Sketch entity types and Feature
   types listed in `00-conventions.md`'s v1 scope boundary section, and
   nothing else. The model should be told explicitly what it *can't*
   generate (Spline, Text, Loft, assemblies, etc.) so a request that needs
   one of those gets a clarifying pushback ("I can approximate this with
   a Rectangle + Fillets, would that work?") rather than a plan
   referencing a step kind the translator doesn't understand.
2. **Ask before generating.** Keep asking clarifying questions (missing
   dimensions, ambiguous features, tolerances) until confident enough to
   propose a plan — mirrors this very scoping session's own working
   style, which is the explicit precedent named in the original ask.
3. **Gear intent detection.** If the request is gear/rack-shaped, prefer
   emitting the gear-routing step kind (`00-conventions.md`) over a
   generic Feature sequence.
4. **Termination shape.** Once ready, respond with *only* the structured
   plan (workstream 3's schema), fenced/embedded so workstream 1's
   plan-detection fallback can reliably extract it regardless of whether
   the active provider's structured-output support is confirmed.

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

## Scope note

No image handling in this workstream — text input only. Workstream 6
extends `AiChatMessage` and this screen's input row once it becomes the
active workstream; nothing here should be built in a way that blocks that
extension (e.g. don't hardcode the input row to text-only in a way that's
awkward to add an attach-image affordance to later), but don't build any
image UI now either.
