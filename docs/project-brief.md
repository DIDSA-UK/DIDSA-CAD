# Project Brief: Modular Parametric CAD Tool

## 1. Vision

A self-hosted, containerized parametric CAD tool built on the OpenCascade (OCCT) geometry kernel, controlled by a single cross-platform client (Windows / Android / iOS). The system is explicitly modular: each CAD capability (Sketch, Extrude, Revolve, and future features) is an independent module so new features can be added without reworking existing ones.

This is a learning project as well as a tool — architecture decisions favour clarity and modularity over short-term speed.

## 2. Hosting Context

- **Server**: Raspberry Pi 5, 4GB RAM, part of an existing Docker-based homelab ("HomHub").
- **Domain/access**: `snail-shell.uk`, via existing Cloudflare Tunnel + Nginx Proxy Manager pattern. New service gets its own subdomain, following the same pattern as existing services (media, music, npm, etc.).
- **Auth**: Cloudflare Access (email-based), consistent with how other admin-style services are already protected.
- **Future migration path**: Minisforum UM790 Pro (x86_64, Ryzen 9) planned as a future host. Architecture must not assume arm64-only — see Section 7.

## 3. Architecture Overview

```
[ Client App (Flutter: Windows/Android/iOS) ]
        |  HTTPS / WebSocket
        v
[ Docker Container on Pi 5 ]
   |-- API layer (FastAPI or similar)
   |-- Dependency graph / document model
   |-- Sketch module
   |-- Extrude module
   |-- Revolve module (future)
   |-- OCCT (pythonocc-core)
```

**Key principle**: the server is stateless between sessions. It does not persist any model data. The client holds the authoritative model and sends it to the server for recompute/export operations. See Section 6.

## 4. Module Breakdown

Each module is independent and only depends on well-defined inputs/outputs — no module reaches into another's internals.

### 4.1 Sketch Module
- A `Sketch` is an independent collection of `Point`s and entities, created on one of three fixed reference planes (`XY`, `XZ`, `YZ`, all through the origin). Multiple `Sketch`es can exist; they never share Points or entities. Arbitrary/custom planes and 3D embedding of plane coordinates into world space are deferred.
- Entities reference `Point`s by id rather than owning coordinates directly. Two entities connect (e.g. to form a rectangle corner) only when deliberately created referencing the same `Point` id — there is no coordinate-matching or tolerance-based auto-merge of coincident Points.
- Entity type for v1: **Line** only (references a start and end `Point`, plus a derived length dimension). Entities are built on a generic base (`SketchEntity`) so future entities (circle, arc, etc.) are added as new entity types without changing how Sketch, Profile, or Extrude work.
- Editing the length dimension moves the end `Point` (direction preserved). Since Points are shared objects, this also moves every other entity referencing that Point — this is the natural and expected behaviour of a shared Point, not a special case.
- No constraint solver in v1 (no coincident/tangent/parallel constraints) — dimensions directly drive raw coordinates.

### 4.2 Profile Detection
- Takes a Sketch's entities and determines whether they form exactly one closed loop, via each entity's two connected Point ids — it has no knowledge of how the entities were created (e.g. it doesn't know "Line", only "an entity that connects two Points").
- Reports four distinct outcomes: a single closed loop (produces an ordered `Profile`), no loop (open chain or no connectable entities), a branch/T-junction (a Point used by 3+ entities), or multiple disjoint loops within one sketch.
- Outputs a closed wire/profile usable by any downstream feature (Extrude, Revolve, etc.).

### 4.3 Extrude Module
- Takes a closed Profile + a height value.
- Calls OCCT's prism/extrude operation (`BRepPrimAPI_MakePrism` or equivalent).
- Outputs a solid + a triangle mesh for client display.
- Knows nothing about Sketch internals.

### 4.4 Revolve Module (planned, not v1)
- Same pattern as Extrude: takes a closed Profile + an axis + an angle, outputs a solid.

### 4.5 Dependency Graph (the core of the system)
- Minimal feature-tree model: `Sketch → Profile → Extrude`.
- Editing an upstream node (e.g. a Line's length) marks downstream nodes dirty and triggers automatic recompute — true parametric history, not manual re-run.
- This graph is the most important piece of engineering in the whole project; it's what makes the system "parametric" rather than just "a 3D viewer."

## 5. Client Interaction Model

### 5.1 Cursor-based input (trackpad style)
- A persistent on-screen cursor exists in the 2D sketch canvas.
- Finger drag (or mouse move on Windows) moves the cursor **relatively**, scaled by a sensitivity factor — not 1:1 with finger position.
- Cursor position persists between separate touches (lifting and touching down again does not jump the cursor).
- A dedicated on-screen **Click button** commits a point at the cursor's current location (creates/finishes a line). No tap-to-click gesture detection.
- On Windows, mouse movement drives the same cursor logic, and a real mouse click performs the same action as the on-screen button (button can be hidden on Windows).

### 5.2 Dimension editing
- Each Line shows an editable length dimension.
- Editing the value sends an update to the backend, which recomputes the dependency graph and returns updated geometry (sketch + any downstream solids).

### 5.3 3D viewport
- Displays the current Extrude/Revolve result as a mesh.
- Updates automatically whenever the backend returns new geometry after a sketch edit.

## 6. Data & File Formats

| Format | Role | Lives where | Direction |
|---|---|---|---|
| Native format (JSON) | Editable parametric model: entities, dimensions, feature tree | Client-side only (file on Windows, app storage on Android/iOS) | Read/write (Open/Save) |
| STEP | Interoperability export for other CAD tools | Generated server-side on request, returned to client | Export only |
| STL | 3D printing / visualization export | Generated server-side on request, returned to client | Export only |

- The server never persists model data. It receives the current model state from the client, computes (recompute, mesh generation, or STEP/STL export), and returns the result.
- STEP/STL are **one-way exports** — they describe final geometry only, not feature history, and are not intended to be re-imported as editable parametric models.
- This statelessness is also what makes the Pi → mini PC migration trivial: there is no persistent data on the server to migrate.

## 7. Technical Risks & Decisions to Settle Early

| Risk | Why it matters | Mitigation |
|---|---|---|
| arm64 build of pythonocc-core/OCCT | Most tutorials/images assume x86_64; Pi 5 is arm64 | Verify in Stage 0 before writing any application code |
| Multi-arch Docker images | Future migration to x86_64 mini PC | Use `docker buildx` to build multi-arch images from the start, even while only deploying to the Pi |
| Mesh size/transfer cost | Network round-trip on every edit, since hosting is internet-facing not LAN | Not a concern at "boxes and cylinders" scale; revisit if complexity grows |
| Backend language choice | Python (pythonocc-core) vs C++ affects dev speed vs performance | Recommend Python/pythonocc-core for v1 — faster to iterate with AI-assisted development; C++ can be revisited later if performance demands it |

## 8. Build Stages (v1 Roadmap)

**Stage 0 — Environment**
Confirm OCCT + pythonocc-core build and run inside a Docker container on the Pi 5 (arm64). No application code yet. This is the de-risking step — confirm before proceeding.

**Stage 1 — Sketch module (backend only, first pass)**
Implement the Line entity with endpoint coordinates and a derived length dimension. Test via direct API calls (e.g. Postman/curl) — no UI yet. *(Superseded by Stage 2 — Lines no longer own coordinates directly.)*

**Stage 2 — Sketcher foundation + Profile**
Rework the Sketch data model before building Extrude: `Point` entities, a generic `SketchEntity` base, the three fixed reference planes, multiple independent Sketches, and closed-loop detection (Profile) — all without a dependency graph yet.

**Stage 3 — Dependency graph + Extrude module + API layer**
Implement the dependency graph connecting Sketch → Profile → Extrude, including dirty-marking and auto-recompute, and the Extrude module consuming a Profile. Wrap Sketch/Profile/Extrude behind an HTTP/WebSocket API. Containerize and expose via the existing Cloudflare Tunnel setup under a new `snail-shell.uk` subdomain, behind Cloudflare Access.

**Stage 4 — Flutter client: 2D canvas**
Build the cursor-based sketch canvas (drag-to-move cursor, Click button to commit points), dimension editing UI, talking to the live API.

**Stage 5 — Flutter client: 3D viewport**
Render the returned extrude mesh; verify it updates live when the sketch changes.

**Recommended approach**: build and fully verify Stages 0–3 using only raw API calls before starting Flutter work (Stage 4+). This isolates backend/parametric bugs from client/rendering bugs.

## 9. Explicitly Out of Scope for v1 (Future Modules)

- Circle and Arc sketch entities
- Constraint solving (coincident, tangent, parallel, etc.)
- Revolve module
- Fillet/Chamfer
- Boolean operations (union/subtract/intersect)
- Multi-user/concurrent editing
- Server-side persistence or accounts

These are deliberately deferred, not forgotten — the modular architecture in Section 4 is designed so each can be added independently later.
