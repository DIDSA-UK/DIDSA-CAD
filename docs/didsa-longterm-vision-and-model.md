# DIDSA — Long-Term Vision & Model Philosophy

**Status: aspirational, long-horizon.** This document captures architectural thinking that should *inform* decisions made today, but it does not gate or reorder the near-term roadmap. `DIDSA-Vision-and-Roadmap.md` owns the actual phase sequence; `docs/sketcher-restructure-plan.md` owns the current sketcher work. Where this document and the near-term roadmap conflict on sequencing, the near-term roadmap wins unless a decision explicitly changes that.

Source: a scoping conversation exploring whether DIDSA's sketcher problems were really sketcher problems, or symptoms of a modelling architecture that hadn't been made explicit yet. That conversation is preserved in full elsewhere; this document distills the conclusions that survived scrutiny into something durable.

---

## 1. Mission statement

**The software should disappear, leaving only the design process.**

Not "AI-first CAD." Not "cross-platform CAD." Not "mobile CAD." Those are all consequences of getting this right, not the goal itself. The test: an engineer who has never used DIDSA sits down, and after an hour says *"why doesn't every CAD package work like this?"* — not because it was fast or AI-powered, but because they never had to stop thinking about the design to think about the software. Current CAD interrupts constantly: open this, find that tool, satisfy this prerequisite before that feature will even let you start. DIDSA's job is to remove those interruptions, not add new ones dressed up as AI.

## 2. Workflow-first, not intent-first or feature-first

Three generations, roughly:
- **CAD 1.0 — geometry-first** (AutoCAD): draw lines.
- **CAD 2.0 — feature-first** (SolidWorks, Fusion, Inventor): parametric features.
- **CAD 3.0 — intent-first**: describe what you want, let the system figure out the geometry.

DIDSA is not aiming for a pure intent-first model — forcing every interaction through "describe your intent" would be as restrictive as forcing everything through a feature tree. Instead: **workflow-first.** The software adapts to how the user wants to work *right now* — sketching, direct editing, AI prompting, or inspecting history — without sacrificing engineering rigour or forcing a paradigm. Sections 4–5 below exist to serve this.

## 3. The design lifecycle

Designs mature through stages, and DIDSA should recognise this rather than treating every model as equally "serious" from the first line drawn.

| Stage | Characteristics | Needs |
|---|---|---|
| **Exploration** | High creativity, low commitment, low detail, disposable ideas | Minimal friction, multi-body by default, loose organisation, quick edits |
| **Design** | Confidence increasing | Fully constrained sketches, parametric dimensions, features, design intent, early material choices |
| **Engineering** | Model becomes authoritative | Assemblies, configurations, manufacturing considerations, simulation, fasteners, tolerances |
| **Delivery** | Audience changes — the software now helps *other people* understand, not the designer decide | Different views for manufacturing, purchasing, customers, certification, management |

This isn't a mode switch the user has to declare. It's context the Context Engine (§5) can use, and a lens for deciding what a given feature needs to support at each point in its life.

## 4. What a CAD model actually is

A CAD model is the full definition of a design: features that create bodies, plus the metrics and text fields attached to them. Some designers think purely in terms of finished bodies; others are constantly aware of sequence and the dependency graph. **Both must have first-class access, always** — this is why the feature-tree breadcrumb pattern (as in SolidWorks) works: it exposes structure without forcing anyone to live in it.

**Multiple views onto one model**, not separate models:

```
Project
├── Feature History   (Sketch 1, Extrude, Fillet, Pattern, ...)
├── Bodies
├── Parts
├── Assemblies
├── Drawings
└── AI Session
```

The underlying data is identical across all of them. An engineer naturally lives in Feature History. A novice might rarely open it. An AI agent might not reference it at all, working purely through the command surface. Nobody loses their preferred way of working, and — critically — this reframes the feature tree from "the one true representation" to "one legitimate view among several," which resolves the earlier temptation to replace it with an "intent tree." The feature tree isn't the problem; having only one view of it was.

A related, smaller consequence: the user shouldn't need to care where a dimension "lives" to change it. "I'm changing the width" should not require knowing it's Sketch 3, Dimension D7 — double-clicking a body to edit an upstream sketch dimension without entering the sketch (already true today) is exactly the right instinct, and should generalise.

## 5. The Context Engine

A **deterministic** (not AI) service answering one question: *given the current selection, the current design-lifecycle stage, and the user's last action, what are the most likely next operations?*

That answer serves every surface identically:
- Right-click / radial menus
- Keyboard shortcuts
- Touch interfaces
- Voice
- AI (as a structured option list, not a blank canvas)

This is also the mobile strategy, and it's worth being explicit that it *validates* rather than replaces what already works: the existing mobile UX — cursor for precision, taps for speed, context drawers that show only the tools relevant to whatever's selected — is already a working instance of this idea. Desktop can expose thousands of commands; mobile exposes the 5–10 the Context Engine judges most relevant right now. Same capability, different presentation density, same underlying logic. This should be preserved and generalised, not redesigned.

This is a real architectural component worth eventually defining explicitly (semantic object model, command system, intent layer, context engine, interaction principles) — but it is not a prerequisite for near-term sketcher work, and should not be used to justify delaying it.

## 6. Semantic objects — deliberately not pursued further than patterns

Considered: should DIDSA let users select "Bolt Pattern" or "Cooling Features" as first-class objects, rather than the underlying holes/pockets? Decided against — a bolt pattern is a pattern; it doesn't need a distinct object type from any other pattern feature. This is the "stay lean" principle in practice: the win from a semantic layer here is speculative, the cost (new object types, new selection/editing paths, more surface area to keep consistent) is concrete. Not revisited unless a specific, demonstrated need appears.

## 7. Assemblies

No forced early split between multi-body parts and assemblies. The user decides when a design graduates — via a single tool that extracts bodies out as parts and brings them into an assembly, rather than two structurally different workflows. Not every body needs to become a part; construction/helper geometry can remain permanently embedded. Both are valid, ongoing workflows, not a part lifecycle everything must pass through.

## 8. AI and engineering decisions

AI should be allowed to make engineering decisions (rib thickness, fillet radius, hole sizing, material) rather than always stopping to ask — but every decision must be justifiable in plain language on request, so an engineer can verify or override it the moment it lands in front of them. This should be reflected directly in the AI-CAD Protocol already scoped in `DIDSA-Vision-and-Roadmap.md` Phase 3: alongside the existing structured outputs (action plan, confidence score, validation feedback), add an explicit **rationale** field per decision.

## 9. History and deletion

Deleting an upstream feature (e.g. Sketch 1, with downstream features depending on it) should not simply cascade-fail or force a manual rebuild. DIDSA should attempt AI-assisted reconstruction of the design intent — but always with an explicit warning of what's about to happen before it happens, never a silent auto-repair. This has real potential to go wrong; it also has real potential to be one of DIDSA's more genuinely useful AI features if it works well. Treat as opt-in-visible, not default-silent, and don't build it until the near-term AI-CAD protocol work (Phase 3 onward) is mature enough to make "explain what you're about to do" a solved pattern elsewhere first.

## 10. Collaboration

Long-horizon, not a near-term commitment — DIDSA is currently single-user. The stated preference is git-like branch/merge, not feature locking (existing PDM-style locking was named explicitly as something to avoid). No architecture work needed now, but the document model should keep avoiding anything that would make a future merge model structurally impossible — stable, diffable feature IDs (already a house rule) are exactly the kind of thing that keeps this door open cheaply.

## 11. Kernel abstraction

OCCT stays the implementation for the foreseeable future — this is explicitly a hobby-scale, one-person project, and a full kernel-abstraction layer isn't warranted today. The cheap insurance worth taking: keep OCCT/pythonocc-core calls behind the existing module boundaries (Sketch / Extrude / Revolve / etc., per `project-brief.md` §4) rather than scattering kernel calls throughout the backend. That's "the application uses OCCT today" rather than "the application is OCCT," at effectively zero extra cost, without building an abstraction layer that has no second implementation to justify it.

## 12. Extensibility

No plugin or scripting surface is being built. The AI-CAD Protocol (already scoped) is the extensibility surface for the foreseeable future, not a separate macro/plugin system. Revisit only if a concrete need for third-party extension appears that the AI protocol genuinely can't serve.

## 13. 3D-native sketching (John's floated idea) — prerequisite cleared 2026-07-16, promoted into the near-term plan

Originally stated here as a genuine long-term direction gated behind a hard technical prerequisite and a documented false start:

- **Prerequisite:** true orthographic projection. Confirmed cleared — a spike (`docs/sketcher-spikes-ffi-and-plane-sketch.md`, Spike B) implemented `OrthographicProjection`/`OrthographicCamera` against `flutter_scene` 0.18.1's own documented extension point (no `MakeOrthographic` factory exists by that name, but the more general mechanism that makes one unnecessary already does) and confirmed on the real test device that it renders and picks correctly, with zero patch or fork needed.
- **Prior art:** the earlier "3D-backdrop hybrid sketching" experiment was pulled specifically because `flutter_scene`'s camera was believed perspective-only (see `docs/sketcher-architecture-ux-scoping.md` §12.7). That premise no longer holds as of the version this project already pins — the same spike's B1 test (tap → ray → `hitTestReferencePlanes` → place a point, under `OrbitCamera`) also confirmed the interaction mechanic itself feels right on-device, after fixing one real bug (a pinch-zoom-direction inversion) found during that test.

**This is now part of `docs/sketcher-restructure-plan.md` (Phase 2, sequenced after the plan's solver-migration work)**, not separate from it — the prerequisite that kept it out is cleared, so the reason to treat it as a distinct, deferred track no longer applies. See that plan's §3 for the reasoning on why it's sequenced after rather than bundled with the solver migration, and §4 Phase 2 for what actually still needs building (full sketch-tool parity, the flat-2D-vs-plane-embedded coexistence question, and the downstream implications for profile detection/OCCT wire construction are all explicitly not yet resolved).

## 14. Migration stance

Evolve the existing repository. No fork, no rewrite — the codebase is in reasonable shape, and a full "Document 6 — Migration Roadmap" comparing current-vs-target architecture isn't needed unless a future decision genuinely can't be reconciled with what exists today. If that happens, write a migration document scoped to that specific divergence at that time, rather than speculatively now.
