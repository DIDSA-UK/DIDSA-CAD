# Workstream 6: Image Input (Deferred)

Read `00-conventions.md` first. **Not v1** — don't start this until
workstreams 1-5 are proven end-to-end on text input. This file records
what this scoping session resolved about it, not a ready-to-implement
spec; a real design pass is still needed before implementation (see the
open items at the end).

## Recorded decisions from this session

- **A dedicated vision/OCR extraction step, not reliance on provider-
  native multimodal understanding.** The user's own call, against this
  document's initial lean the other way (native multimodal is simpler and
  was the recommended default going in). Understood tradeoff: more
  controllable and less tied to whichever provider happens to be active,
  but real, separate computer-vision engineering — genuinely bigger scope
  than anything else in this doc set, and not something to size or start
  from this scoping pass alone.
- **Single-view only for v1-of-image-mode.** A rough hand sketch or one
  clean scanned/photographed drawing view — not multi-view correlation
  (front/top/side needing to be matched into one 3D shape), which is
  explicitly deferred further, past even this workstream's own first cut.
- **A photo of a real, already-existing physical object is an explicit
  non-goal**, not a deferred-but-planned item. This is a materially
  different, harder CV problem (lighting, occlusion, perspective — closer
  to photogrammetry than drawing interpretation), and this codebase
  already has real, still-open pain in that adjacent space: the
  standalone mesh viewer's handling of real photogrammetry-scale exports
  (ODM `.glb` files) has an extended history of format/orientation/
  compression bugs (mirroring, up-axis, Draco compression — see
  `docs/roadmap.md`'s own entries). That history is a reason to stay
  clear of the same problem space here, not a reason to lean into it.

## Consequences of the client-direct decision, for this workstream specifically

Because the AI call is client-direct (`00-conventions.md`), an uploaded
image goes straight from the Flutter client to whichever provider's HTTP
endpoint (cloud or local) — it never touches the CAD backend at all. The
project brief's §7 bandwidth concern ("mesh size/transfer cost... not a
concern at boxes-and-cylinders scale") was about the CAD backend's own
Pi-over-Cloudflare-Tunnel round-trips, which this workstream simply
doesn't add to. The real bandwidth/latency cost here is the client →
provider upload itself (a photo is much larger than a text prompt) — a
UX concern (show upload progress, maybe downscale before sending) rather
than an architectural one.

## Capability gating

`AiProviderCapabilities.supportsVision` (workstream 1) should gate the
image-upload affordance entirely — greyed out / hidden with an
explanatory note when the active provider doesn't advertise vision
support, rather than silently sending an image to a text-only model and
producing a confusing failure. Real local/open vision models are expected
to lag meaningfully behind top cloud multimodal models specifically at
reading precise technical drawings — this is the sharpest local-vs-cloud
capability gap in the whole feature, and the UI should say so plainly
rather than let a user discover it via a bad result.

## UX carried over from workstream 2

Per the original scoping conversation's own resolution: the uploaded
image stays pinned/visible in the chat panel for the duration of scoping
(so a clarifying question can reference a region of it — "the callout
near the top-right, is that 45mm?"), not consumed and discarded after a
single upload turn.

## Open items — not resolved, needs its own scoping pass before implementation

- What the "dedicated extraction step" actually *is* — no candidate
  library/approach/architecture has been chosen. This needs real research
  (OCR engine options, whether a general vision model doing structured
  extraction counts as "dedicated enough," accuracy expectations against
  real hand sketches vs. clean drawings) before schema/field names get
  locked in, the same way this project's own Text-tool font work did a
  real on-device capability check before committing to field names
  (`docs/roadmap.md`'s Text tool entry) — recommended precedent to follow
  here too.
- Exactly how extracted structured data feeds into workstream 3's plan
  schema — presumably as additional scoping-conversation context rather
  than a schema change itself, but not designed.
- Payload size handling in the client (compression/downscale before
  upload) — not designed.
