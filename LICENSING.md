# Licensing

DIDSA-CAD is one repository with several licences, chosen by folder. Every licensed folder contains its own `LICENSE`; the
full texts are also in [`LICENSES/`](LICENSES/) and the folder-to-licence map is machine-readable in [`REUSE.toml`](REUSE.toml)
(the [REUSE](https://reuse.software) convention: `reuse lint` checks it).

| Folder | SPDX identifier | In short |
|---|---|---|
| `backend/` | `AGPL-3.0-only` | Strong copyleft **including network use**: if you run a modified backend for other people to use over a network, you must offer them its source. |
| `client/` | `Apache-2.0` | Permissive: use, modify, and ship it (including in closed or App Store apps) if you keep the licence and notice and state changes. Includes a patent grant. |
| `tools/gui_harness/` | `AGPL-3.0-only` | Test tooling that imports backend code, so it follows the backend. |
| `tools/solvespace-reference/` | `GPL-3.0-only` | Test-only reference solver built from SolveSpace (GPL v3). Never part of the app. |
| `client/assets/fonts/`, `backend/app/sketch/fonts/` | `OFL-1.1` | Third-party fonts, each with its own `OFL.txt`. |
| `browser-relay/`, `docs/`, `tools/motion_*`, root files | `GPL-3.0-only` | Unchanged from before the split; **see open decisions below**. |

## Why this split

- The backend links `py-slvs` (the SolveSpace constraint solver, **GPL v3**) and uses OCCT / pythonocc-core (LGPL). Distributing
  the backend therefore requires a GPL-compatible licence. AGPL v3 is GPL-compatible (GPL v3 section 13 permits combining the
  two) and additionally covers hosted use.
- The client contains **no GPL or AGPL code**. Since the projector work, the shipped app does not load SolveSpace at all; the
  per-frame drag clamp is the pure-Dart `client/lib/sketch/projector/`. The client talks to the backend only over HTTP, as a
  separate program. That is what allows a permissive client licence and an App Store build.
- `tools/solvespace-reference/` is where the SolveSpace fork, its FFI shim and its build recipe now live (they used to sit under
  `client/native/slvs`). Some client tests can optionally load a locally built copy to cross-check the projector (they skip when it
  is absent, as in CI); the Dart bindings those tests use (`client/test/support/slvs_reference/`) are this project's own code and
  contain no SolveSpace source. Nothing there is built into, bundled with or required by the app.

## Rules that keep it clean

1. **No code flows from `backend/` (or `tools/solvespace-reference/`) into `client/`.** A copied function would pull the AGPL/GPL
   into the Apache client. Share data shapes through the HTTP API, not by copying source.
2. Anything the client needs from SolveSpace stays on the test side, loaded at runtime from `tools/solvespace-reference/`.
3. New files go in the folder whose licence you intend; do not drop a file into `client/` that you copied from elsewhere without
   checking its licence.
4. Contributions are accepted under the licence of the folder they touch.

## Open decisions (for the project owner)

- **Copyright holder and year.** Files and `client/NOTICE` say "2026 DIDSA-UK and contributors". Replace with the correct legal
  name if different, and settle who owns contributions made so far before relicensing anything others wrote.
- **`docs/`, `browser-relay/`, `tools/motion_*`.** Left on GPL v3 because nothing says otherwise. Documentation is often put under
  CC BY 4.0 and `browser-relay/` is a separate service for another product; decide each.
- **Logo and brand.** `client/assets/images/` and the root banner are covered by the folder's licence in `REUSE.toml`. If the DIDSA
  name and logo should be reserved, say so in a trademark note and exclude them.
- **`-only` vs `-or-later`.** Identifiers use the stricter `-only`; switch to `-or-later` if you want to allow future GNU versions.
- **Per-file headers.** Not added (they would touch every file). `REUSE.toml` carries the licensing instead; adding
  `SPDX-License-Identifier` headers later is mechanical.
- **Legal review.** This was prepared by an AI assistant, not a lawyer. Have someone qualified review it before publishing a build,
  in particular the Apple App Store terms and the AGPL network clause as it applies to how people will run the backend.
