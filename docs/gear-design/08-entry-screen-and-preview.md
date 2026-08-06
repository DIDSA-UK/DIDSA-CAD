# Workstream 8 — Gear Design entry screen (client) and its 2D preview

Read `00-conventions.md` first (field input style, `GearGroup` color-
coding). Depends on Workstream 1 (for `/gear/preview`) and benefits from
Workstream 2 existing first (so there's a real gear type to preview/create
before every type is done).

## Scope

New `ToolChooserScreen` tile ("Gear Design") → a dedicated screen (closer
in shape to `SketchScreen` than a compact `ResizableToolPanel`, since it
needs a 2D canvas alongside a form): a gear-type selector (external /
internal / rack / helical / herringbone / pair-or-chain / planetary /
bevel gear / bevel pair) and a form of fields per type, next to a live 2D
preview canvas.

### Preview mechanism

Add a cheap `GET/POST /gear/preview` endpoint that runs *only*
`gear_math`/`bevel_math` (no OCCT solid construction, no tessellation) and
returns raw 2D point arrays (tooth outline, plus pitch/base/addendum/
dedendum circle radii for the reference overlay). Cheap enough to call on
every debounced keystroke, same rhythm every other panel's live-PATCH
already uses, without duplicating the math client-side and without paying
for a full OCCT extrude+mesh cycle on every field edit. The **expensive**
path — a real Feature, real OCCT solid — only runs on debounce-settle or
explicit "Create."

### Chain/planetary/bevel-pair preview

`/gear/preview` extended to accept a multi-gear payload (stage list +
turn angles; or sun/ring/planet-count; or two bevel gear specs + shaft
angle), returning every member's outline + computed center + reference
circles, so the real layout (including a bent chain's actual route) is
visible while still editing. Any interfering non-adjacent pair
(`05-gear-chain-and-planetary.md`) is highlighted directly on the
offending gears. Surfaces two cheap numbers from the same math: **overall
ratio** and **rotation direction** per stage/link (external-external
reverses, external-internal doesn't, rack direction depends on
orientation, a compound station never reverses — see
`05-gear-chain-and-planetary.md`'s compound-gear ratio rule).

### Reference circle overlay

On by default, toggleable. Pitch/base/addendum/dedendum circles drawn
alongside the tooth outline from the same `/gear/preview` response.

### Group color-coding

Each stage's outline tinted by its `GearGroup`'s `display_color`. A no-op
for v1's single-implicit-group chains (everything one color), but costs
nothing to build now and is what makes a future multi-group/compound
chain self-explanatory at a glance.

### Field input style

Dropdown of standard module/pressure-angle values with a "custom"
override — see `00-conventions.md`.

### Create

Adds a Part (or opens the current one) with the resulting Feature(s),
handing off to the normal `PartScreen` 3D-viewport flow. Editing
afterward is the ordinary Feature-tree edit flow (reopen while still the
last Feature, or roll back via `Part.is_locked`) — nothing gear-specific
to add there.

## Complexity/risk

Medium. Mostly UI work following this codebase's existing tool-panel/
value-bar conventions (`ExtrudePanel`, `FilletPanel`); the one new backend
piece is the cheap `/gear/preview` endpoint, a thin wrapper around
Workstream 1/10's math, which should ship alongside them.
