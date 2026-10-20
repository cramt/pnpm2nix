# pnpm2nix — Improvement Backlog

Profiled against a rezip monorepo checkout (3,162 packages, 3,179 snapshots,
29 importers, 10 dep cycles). Benchmarks on ext4 (no reflinks), warm
fetch/extract caches.

---

## ~~P0 — Monolithic farm rebuild~~ ✓ DONE (cells + compose)

Replaced the single-derivation farm with per-snapshot cell derivations
(grouped by dep-graph SCC) plus pure-symlink compose layers, one per
importer pruned to its closure. See ARCHITECTURE.md.

Measured on the profiled monorepo:

| Scenario | Old (monolith) | New (cells) |
|----------|---------------|-------------|
| Farm rebuild after any lockfile change | 3m 13s + all apps rebuild | — |
| Cold build of the whole farm layer | 3m 13s (farm only) | 2m 02s (all 3,168 cells) |
| Worst-case bump (tslib, ~340 rev-deps) | 3m 13s | 44s (276 cells) |
| Apps rebuilt on a single-app dep bump | all | only the affected app |

## P1 — Lifecycle scripts (`onlyBuiltDependencies`)

Workspace packages' own `prepare` scripts now run (one derivation per
package, overlaid into every build). What follows is about *dependencies'*
install scripts, which still don't.

Packages with `postinstall` scripts (esbuild, sharp, workerd) are extracted
but their lifecycle scripts are NOT run. The `onlyBuiltDependencies` field
in `pnpm-workspace.yaml` is not honored. Packages that need native binaries
from postinstall will have broken binaries. With cells this is now *cheaper*
to fix than before: run the script in the affected package's cell build
(the cell has its full dep tree resolvable via its own node_modules links).

## P2 — JSON manifest instead of inline script

Cell derivation scripts are small, but the compose layers still inline one
`ln -s` line per snapshot (~2,800 lines for the full farm, less for pruned
per-importer composes). Moving the pairs into a `builtins.toFile` JSON
manifest + a fixed jq loop would shrink the .drv files. Lower priority now
that composes are the only per-change derivations and they're already thin.

## P3 — Extract bin info in parser.py

`nodeModules.nix` shells out to `jq` at build time to read each dependency's
`package.json` for bin entries, once per top-level dep per importer. The
`hasBin` boolean is already in the parser output — at minimum, gate the
`populate_bin_for_pkg` call on it.

## P4 — Kill the IFD cold start

Optional codegen mode: commit the parsed lockfile JSON (generated via
`nix run .#lock` or a pre-commit hook) and skip the Python/PyYAML IFD
entirely, crane-style. Keep IFD as the zero-setup default.

## P5 — Single-package (non-workspace) entry point

`mkPnpmPackage { src }` for plain single-package repos — same pipeline, one
implicit importer. Rounds out the API for the crane-like "5 lines for any
repo" experience.
